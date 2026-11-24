#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The background pass that learns from what Ghost saw. Once an hour the digest reads what is new since the last one: each chat's
/// messages, each meeting summary written since, the task list, the screen captures when `memory.learnFromScreen` is on, and any page
/// with more claims than `memory.maxClaimsPerEntity`, which it merges. An automation's final answer is read when it arrives. Each run
/// sends only what is new to one agent, with the notes Ghost already has, and saves what the agent names through `MemoryStore`. One run
/// at a time.
///
/// The agent runs restricted, like meeting summaries: no MCP servers, a scratch folder, every permission request refused. It only
/// answers with JSON; ironpet checks each note and writes the claims. Text only goes to an agent that already had it: a chat to its own
/// agent, a meeting summary to the summary agent, an automation's answer to the agent that ran it. Tasks, screen text and merges go to
/// the digest agent, the one that already reads chats (`memory.reflectAgent`, else the chat's agent).
@MainActor
package final class MemoryReflector {
    /// Why the reflection agent gave no answer.
    package struct RunError: Error, Equatable {
        package let message: String
        package init(_ message: String) { self.message = message }
    }

    /// The agent that reads one job, and its model (nil: the agent's default).
    package struct Reader: Equatable {
        package init(agent: String, model: String?) {
            self.agent = agent
            self.model = model
        }

        package let agent: String
        package let model: String?
    }

    /// Runs one prompt on the reader's agent and returns its answer, or why it failed.
    package typealias Runner = @MainActor (_ prompt: String, _ reader: Reader) async -> Result<String, RunError>

    package enum Job: Equatable {
        case thread(String)
        /// `agent` wrote the summary, recorded when it was written.
        case meeting(URL, agent: String)
        /// Only the run's final answer, never the item text an automation fetched. `agent` is the one that ran it.
        case automation(id: String, name: String, answer: String, agent: String)
        /// The tasks that are new or changed since the last digest.
        case tasks(agent: String)
        /// The screen captures since the last digest.
        case screen(agent: String)
        /// The oldest facts of one page that holds more than `memory.maxClaimsPerEntity`, merged into fewer.
        case merge(entity: String, agent: String)
    }

    package struct Outcome: Equatable {
        package init(job: Job, saved: [String] = [], dropped: [String] = [], error: String? = nil, skipped: Bool = false) {
            self.job = job
            self.saved = saved
            self.dropped = dropped
            self.error = error
            self.skipped = skipped
        }

        package var job: Job
        package var saved: [String] = []
        package var dropped: [String] = []
        package var error: String?
        /// True when there was nothing new to read, learning is off, or the text went to another agent than the reader.
        package var skipped = false
    }

    /// Read from `memory.reflectMaxNotes`, `memory.reflectMaxInputChars` and `memory.reflectTimeoutSeconds` each time, so an edit
    /// in config.json applies to the next pass.
    package static var maxNotes: Int { ConfigStore.shared.config.memory.reflectMaxNotes }
    package static var maxInput: Int { ConfigStore.shared.config.memory.reflectMaxInputChars }
    package static var timeout: TimeInterval { TimeInterval(ConfigStore.shared.config.memory.reflectTimeoutSeconds) }
    /// Most merges one pass of the merge job may make.
    package static let maxMerges = 5
    /// Most of a page's oldest facts one merge pass shows the agent.
    package static let maxMergeCandidates = 40
    /// The cursor row that says earlier chats were marked as read.
    package static let seededKey = "catch-up:seeded"
    /// The cursor row of the last screen capture a digest read.
    static let screenKey = "screen"

    package let store: EntityMemoryStore
    package let index: MemoryIndex
    package var runner: Runner
    package var config: () -> Config.Memory = { ConfigStore.shared.config.memory }
    package var now: () -> Date = Date.init
    package var threads: (String) -> ChatThread? = ThreadStore.load
    package var recentThreads: () -> [ChatThread] = { ThreadStore.recent(limit: 50, automationLimit: 0) }
    package var tasks: () -> [TaskItem] = { [] }
    /// Newest first, as `CaptureStore.recent` returns them.
    package var captures: () -> [StoredCapture] = { [] }
    /// The chat's agent, which reads tasks, screen text and merges when `memory.reflectAgent` is not set.
    package var digestAgent: () -> String? = { nil }
    package var petName: () -> String = { ConfigStore.shared.config.pet.name }
    /// Shows a question in the alerts, such as which of two people a name means.
    package var post: (Signal) -> Void = { _ in }
    /// Off in test mode, where only `reflectNow` runs a pass, so an e2e scenario never writes notes it did not ask for.
    package var automatic = true
    /// Called after a run saved notes or failed, so Settings can refresh and show the failure.
    package var onChange: (() -> Void)?

    package private(set) var queue: [Job] = []
    package private(set) var running: Job?
    package private(set) var lastOutcome: Outcome?
    /// When the last digest ran. Nil until one has.
    private var lastDigest: Date?
    /// Meeting summaries written since the last digest, and the agent that wrote each.
    private var pendingMeetings: [(folder: URL, agent: String)] = []
    private var waiting: [(Job, CheckedContinuation<Outcome, Never>)] = []
    /// Bumped by `cancelAll`, so the answer of a run that started before it is thrown away.
    private var generation = 0
    /// The last answer of each automation that was queued, so a watcher that says the same thing every run is read once.
    private var lastAnswers: [String: String] = [:]

    /// `spawner` starts the default runner's agent. A `runner` passed in does not use it.
    package init(store: EntityMemoryStore, index: MemoryIndex, spawner: ProcessSpawner = UnsupportedProcessSpawner(), runner: Runner? = nil) {
        self.store = store
        self.index = index
        self.runner = runner ?? { prompt, reader in await MemoryReflector.agentRunner(prompt: prompt, reader: reader, spawner: spawner) }
    }

    // MARK: Triggers

    /// Runs the digest when `memory.digestMinutes` have passed since the last one, or when none has run yet. The app calls it every minute.
    package func tick() {
        guard automatic else { return }
        if let lastDigest, now().timeIntervalSince(lastDigest) < Double(config().digestMinutes) * 60 { return }
        digest()
    }

    /// The hourly digest: queues what is new since the last one.
    package func digest() {
        guard automatic, config().reflect else { return }
        lastDigest = now()
        let config = config()
        for thread in recentThreads() where !thread.isAutomationRun && thread.job == nil && config.reader(for: thread.agent) != nil {
            if !unread(in: thread).isEmpty { enqueue(.thread(thread.id)) }
        }
        for meeting in pendingMeetings { enqueue(.meeting(meeting.folder, agent: meeting.agent)) }
        pendingMeetings = []
        // Tasks, screen text and merges go to the chat's agent: it already reads the tasks and the captures through its tools. Under a picked
        // agent they go only when that is the chat's agent, since `reader(for:)` skips other text.
        guard let agent = digestReaderAgent(), config.reader(for: agent) != nil else { return }
        if !changedTasks().isEmpty { enqueue(.tasks(agent: agent)) }
        if config.learnFromScreen, !freshCaptures().isEmpty { enqueue(.screen(agent: agent)) }
        for entity in store.entities() where store.claims(of: entity.id).count > config.maxClaimsPerEntity {
            enqueue(.merge(entity: entity.id, agent: agent))
        }
    }

    /// A meeting summary was written. It is read by the next digest, by the agent that wrote it.
    package func meetingSummaryWritten(_ folder: URL, agent: String) {
        guard automatic, config().reflect, !pendingMeetings.contains(where: { $0.folder == folder }) else { return }
        pendingMeetings.append((folder, agent))
    }

    /// An automation's final answer, from the agent that ran it. Its quiet reply, and an answer the same as its last one, are skipped.
    package func automationFinished(id: String, name: String, answer: String, agent: String, quiet: [String] = []) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard automatic, config().reflect, !text.isEmpty, !quiet.contains(text),
              lastAnswers[id] != text else { return }
        lastAnswers[id] = text
        enqueue(.automation(id: id, name: name, answer: text, agent: agent))
    }

    /// At launch: the recent threads with messages no run has read, newest first.
    /// Once, at the first launch with memory: marks the chats from before it as read, so the update itself sends none of them. Runs
    /// whether or not learning is on, since it only writes cursors, and before any trigger can fire.
    package func seedIfNeeded() {
        guard index.cursor(Self.seededKey) == nil else { return }
        for thread in recentThreads() {
            if let last = thread.items.last, index.cursor(thread.id) == nil { index.setCursor(thread.id, item: last.id.uuidString, at: now()) }
        }
        index.setCursor(Self.seededKey, item: "1", at: now())
    }

    /// Forget Everything: drops the queued jobs and the run in flight saves nothing.
    package func cancelAll() {
        pendingMeetings = []
        queue = []
        generation += 1
        let dropped = waiting.filter { $0.0 != running }
        waiting.removeAll { $0.0 != running }
        for (job, continuation) in dropped { continuation.resume(returning: Outcome(job: job, skipped: true)) }
    }

    /// Runs the job now (after any that are already queued) and returns what it did. For the test endpoint.
    package func reflectNow(_ job: Job) async -> Outcome {
        return await withCheckedContinuation { continuation in
            waiting.append((job, continuation))
            enqueue(job, force: true)
        }
    }

    /// The agent that reads tasks, screen text and merges: the chat's agent. Nil when no chat has an agent yet.
    package func digestReaderAgent() -> String? {
        digestAgent()
    }

    private func enqueue(_ job: Job, force: Bool = false) {
        if force || (!queue.contains(job) && running != job) { queue.append(job) }
        pump()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = job
        let generation = generation
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.perform(job, generation: generation)
            self.lastOutcome = outcome
            self.running = nil
            // A meeting summary's cursor did not move, so the next digest must queue it again; it is not in `pendingMeetings` any more.
            if outcome.error != nil, case .meeting(let folder, let agent) = job, !self.pendingMeetings.contains(where: { $0.folder == folder }) {
                self.pendingMeetings.append((folder, agent))
            }
            if let at = self.waiting.firstIndex(where: { $0.0 == job }) { self.waiting.remove(at: at).1.resume(returning: outcome) }
            if !outcome.saved.isEmpty || outcome.error != nil { self.onChange?() }
            self.pump()
        }
    }

    // MARK: Input

    /// The user's and Ghost's messages after the cursor, as `(item id, speaker, text)`. Tool output, screenshots and errors are left out,
    /// and so are automation turns: their prompt and the reply to it. An automation's answer is read on its own, as outside text.
    package func unread(in thread: ChatThread) -> [(id: String, user: Bool, text: String)] {
        let cursor = index.cursor(thread.id)
        var start = 0
        if let cursor {
            if let at = thread.items.firstIndex(where: { $0.id.uuidString == cursor.item }) {
                start = at + 1
            } else {
                start = thread.items.firstIndex { ($0.date ?? .distantPast) > cursor.at } ?? thread.items.count
            }
        }
        var automationTurn = false
        var result: [(id: String, user: Bool, text: String)] = []
        for (offset, item) in thread.items.enumerated() {
            switch item.kind {
            case .user(let text):
                automationTurn = item.origin == ChatSession.automationOrigin
                if offset >= start, !automationTurn { result.append((item.id.uuidString, true, text)) }
            case .assistant(let text):
                if offset >= start, !automationTurn { result.append((item.id.uuidString, false, text)) }
            default:
                break
            }
        }
        return result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The newest messages that fit in `maxInput` characters, oldest first.
    package func transcript(_ messages: [(id: String, user: Bool, text: String)]) -> String {
        var lines: [String] = [], used = 0
        for message in messages.reversed() {
            let line = (message.user ? "User: " : "\(petName()): ") + message.text
            if used + line.count > Self.maxInput {
                if lines.isEmpty { lines.append(String(line.suffix(Self.maxInput))) }
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.reversed().joined(separator: "\n\n")
    }

    /// The tasks whose title, notes or status differ from what the last digest saw, with the stamp to store for each.
    private func changedTasks() -> [(task: TaskItem, stamp: String)] {
        tasks().compactMap { task in
            let stamp = Self.stamp("\(task.title)\n\(task.notes)\n\(task.status)")
            return index.cursor(Self.taskKey(task.id))?.item == stamp ? nil : (task, stamp)
        }
    }

    /// The screen captures newer than the last digest read, newest first.
    private func freshCaptures() -> [StoredCapture] {
        let last = Int64(index.cursor(Self.screenKey)?.item ?? "") ?? 0
        return captures().filter { $0.id > last }
    }

    private static func taskKey(_ id: String) -> String { "task:" + id }

    private static func stamp(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private struct Input {
        let text: String
        let kind: String
        let source: String
        /// The agent that already had this text.
        let agent: String
        let project: ProjectKey?
        /// Meeting summaries, automation answers, tasks and screen text hold what other people wrote or saw. They may not write `me.md`.
        let outside: Bool
        /// The cursors to move once the run succeeds, or when there is nothing to read.
        let cursors: [(key: String, item: String)]
    }

    private func input(for job: Job) -> Input? {
        switch job {
        case .thread(let id):
            guard let thread = threads(id), !thread.isAutomationRun, thread.job == nil else { return nil }
            let messages = unread(in: thread)
            guard !messages.isEmpty, let last = thread.items.last else { return nil }
            return Input(text: transcript(messages), kind: "a chat between the user and \(petName())", source: "chat:" + id.prefix(8),
                         agent: thread.agent, project: MemoryMCP.project(URL(fileURLWithPath: thread.workspace)), outside: false,
                         cursors: [(key: id, item: last.id.uuidString)])
        case .meeting(let folder, let agent):
            guard let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8),
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let key = "meeting:" + folder.path
            let digest = Self.stamp(summary)
            guard index.cursor(key)?.item != digest else { return nil }
            return Input(text: String(summary.prefix(Self.maxInput)), kind: "the summary of a meeting the user recorded",
                         source: "meeting:" + folder.lastPathComponent, agent: agent, project: nil, outside: true, cursors: [(key: key, item: digest)])
        case .automation(let id, let name, let answer, let agent):
            return Input(text: String(answer.prefix(Self.maxInput)), kind: "the answer \(petName()) gave in the automation \"\(name)\"",
                         source: "automation:" + id, agent: agent, project: nil, outside: true, cursors: [])
        case .tasks(let agent):
            // Whole tasks only, newest first, so a long list is read in part and the rest is read by a later digest.
            var lines: [String] = [], cursors: [(key: String, item: String)] = [], used = 0
            for (task, stamp) in changedTasks() {
                let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                let line = "- \(task.title) (\(task.status))" + (notes.isEmpty ? "" : ": \(notes)")
                if used + line.count > Self.maxInput { break }
                lines.append(line)
                cursors.append((key: Self.taskKey(task.id), item: stamp))
                used += line.count + 1
            }
            guard !lines.isEmpty else { return nil }
            return Input(text: lines.joined(separator: "\n"), kind: "the user's task list, the tasks that are new or changed",
                         source: "tasks", agent: agent, project: nil, outside: true, cursors: cursors)
        case .screen(let agent):
            // A job queued before the switch was turned off must not read the screen after it.
            guard config().learnFromScreen else { return nil }
            let fresh = freshCaptures()
            guard let newest = fresh.first else { return nil }
            // The newest captures that fit, oldest first. The cursor moves past all of them, so older ones are not read later.
            var lines: [String] = [], used = 0
            for capture in fresh {
                let line = "\(capture.appName) · \(capture.window): \(capture.text)"
                if used + line.count > Self.maxInput {
                    if lines.isEmpty { lines.append(String(line.suffix(Self.maxInput))) }
                    break
                }
                lines.append(line)
                used += line.count + 1
            }
            return Input(text: lines.reversed().joined(separator: "\n\n"), kind: "the text on the user's screen, as captured while they worked",
                         source: "screen", agent: agent, project: nil, outside: true, cursors: [(key: Self.screenKey, item: String(newest.id))])
        case .merge:
            return nil
        }
    }

    private func perform(_ job: Job, generation started: Int) async -> Outcome {
        if case .merge(let entity, let agent) = job { return await merge(entity, agent: agent, generation: started) }
        var outcome = Outcome(job: job)
        let config = config()
        guard config.reflect, let input = input(for: job), let found = config.reader(for: input.agent) else {
            if config.reflect, let input = input(for: job) { moveCursors(input.cursors) }
            outcome.skipped = true
            return outcome
        }
        let reader = Reader(agent: found.agent, model: found.model)
        // The agent of a meeting summary or an automation answer never got a preamble, so it gets no notes either. Outside text can't
        // write me.md or replace notes, and the store drops a note it already has.
        let notes = input.outside ? [] : currentNotes(input.project, about: input.text)
        let prompt = Self.prompt(input: input.text, kind: input.kind, notes: notes, outside: input.outside,
                                 hasProject: input.project != nil, petName: petName())
        let answer = await runner(prompt, reader)
        // Forget Everything, or the switch turned off, while the agent ran.
        guard generation == started, self.config().reflect else {
            outcome.skipped = true
            return outcome
        }
        switch answer {
        case .failure(let failure):
            // The cursors stay, so the next digest reads these messages again.
            outcome.error = failure.message
            NSLog("ironpet: memory reflection failed: \(failure.message)")
            return outcome
        case .success(let answer):
            guard let proposals = Self.parse(answer) else {
                outcome.error = "the agent did not answer with the notes JSON"
                return outcome
            }
            // Like forget, one pass may replace at most `maxForget` notes in all, so a misled pass cannot empty a page.
            var replaced = 0
            for proposal in proposals.prefix(Self.maxNotes) {
                if let reason = Self.refusal(proposal, outside: input.outside, hasProject: input.project != nil) {
                    outcome.dropped.append("\(proposal.text) (\(reason))")
                    continue
                }
                if proposal.scope == .people, let name = MemoryNote.personName(proposal.person), let candidates = store.ambiguousPeople(name) {
                    ask(name, candidates: candidates)
                    outcome.dropped.append("\(proposal.text) (more than one person is called \(name))")
                    continue
                }
                guard replaced + proposal.replaces.count <= MemoryNote.maxForget else {
                    outcome.dropped.append("\(proposal.text) (this pass already replaced \(replaced) of at most \(MemoryNote.maxForget) notes)")
                    continue
                }
                replaced += proposal.replaces.count
                switch store.replace(proposal.replaces, with: proposal.text, scope: proposal.scope, person: proposal.person,
                                     project: input.project, source: input.source) {
                case .success(let note):
                    outcome.saved.append(note.text)
                case .failure(let failure):
                    outcome.dropped.append("\(proposal.text) (\(failure.message))")
                }
            }
            // After the notes, so a person the pass just named already has a page to link.
            for link in Self.parseLinks(answer).prefix(Self.maxNotes) {
                guard let from = resolve(link.from), let to = resolve(link.to), from != to else { continue }
                store.link(from: from, to: to, type: link.type, source: input.source)
            }
            moveCursors(input.cursors)
            return outcome
        }
    }

    private func moveCursors(_ cursors: [(key: String, item: String)]) {
        for cursor in cursors { index.setCursor(cursor.key, item: cursor.item, at: now()) }
    }

    /// The page a name in an answer names: the one match, or nil when none or more than one page has it.
    private func resolve(_ name: String) -> String? {
        switch EntityMatcher.match(name: name, in: store.entities().map(\.record)) {
        case .found(let id): return id
        case .none, .ambiguous: return nil
        }
    }

    /// Asks the user which of several pages a name means. Nothing is guessed: the fact waits until they say.
    private func ask(_ name: String, candidates: [String]) {
        let list = candidates.joined(separator: " or ")
        post(Signal(id: "memory-ambiguous:" + EntityMatcher.normalize(name), title: "Which \(name)?",
                    subtitle: "\(list). Ghost did not guess.", url: nil, label: "Memory", symbol: "person.2.fill", mood: .needsInput,
                    ask: "Which \(name) did I mean: \(list)? Tell me, so I can note it for the right one."))
    }

    /// One merge pass on a page that holds too many claims: the oldest unpinned facts go to the agent, which answers with the merges.
    private func merge(_ entity: String, agent: String, generation started: Int) async -> Outcome {
        let job = Job.merge(entity: entity, agent: agent)
        var outcome = Outcome(job: job)
        let settings = config()
        let claims = store.claims(of: entity)
        let overflow = claims.count - settings.maxClaimsPerEntity
        guard settings.reflect, overflow > 0, let found = settings.reader(for: agent) else {
            outcome.skipped = true
            return outcome
        }
        // The oldest unpinned facts: enough to bring the page under the limit, and a few more to merge.
        let oldest = Array(claims.filter { !$0.pinned }.reversed().prefix(min(Self.maxMergeCandidates, max(2, overflow + 4))))
        guard oldest.count >= 2 else {
            outcome.skipped = true
            return outcome
        }
        let facts = oldest.map { "\($0.ref): \($0.text)" }.joined(separator: "\n")
        let prompt = Prompts.render(id: "memory-merge", [
            "pet": petName(), "claims": facts, "maxLength": String(MemoryNote.maxLength),
        ])
        let answer = await runner(prompt, Reader(agent: found.agent, model: found.model))
        guard generation == started, self.config().reflect else {
            outcome.skipped = true
            return outcome
        }
        switch answer {
        case .failure(let failure):
            outcome.error = failure.message
            NSLog("ironpet: memory merge failed: \(failure.message)")
        case .success(let answer):
            guard let merges = Self.parseMerges(answer) else {
                outcome.error = "the agent did not answer with the merges JSON"
                return outcome
            }
            let shown = Dictionary(oldest.map { ($0.ref, $0.id) }, uniquingKeysWith: { first, _ in first })
            for item in merges.prefix(Self.maxMerges) {
                let ids = item.ids.compactMap { shown[$0] }
                guard Set(item.ids).count >= 2, ids.count == item.ids.count else {
                    outcome.dropped.append("\(item.text) (it names claims that were not shown)")
                    continue
                }
                switch store.merge(entity, replacing: ids, with: item.text, source: "digest:merge") {
                case .success(let note): outcome.saved.append(note.text)
                case .failure(let failure): outcome.dropped.append("\(item.text) (\(failure.message))")
                }
            }
        }
        return outcome
    }

    /// The notes the agent compares against: the same budget and the same choice of people as a chat's preamble, so the reflection
    /// agent gets no more of the notes than any chat with it does.
    private func currentNotes(_ project: ProjectKey?, about text: String) -> [(String, String)] {
        func recall(_ scope: MemoryScope) -> String {
            store.recall(scope, project: project, bytes: MemoryPreamble.budget[scope]!, naming: text)
        }
        var notes = [("me.md", recall(.me))]
        if let project { notes.append(("project \(project.name)", recall(.project))) }
        notes.append(("people.md", recall(.people)))
        return notes
    }

    // MARK: Prompt and answer

    package struct Proposal: Equatable {
        package init(scope: MemoryScope, text: String, person: String? = nil, replaces: [String]) {
            self.scope = scope
            self.text = text
            self.person = person
            self.replaces = replaces
        }

        package var scope: MemoryScope
        package var text: String
        package var person: String?
        package var replaces: [String]
    }

    package static func prompt(input: String, kind: String, notes: [(String, String)], outside: Bool, hasProject: Bool, petName: String) -> String {
        var scopes = outside ? [] : ["\"me\" for the user's own preferences, habits and facts about them"]
        if hasProject { scopes.append("\"project\" for conventions and facts about the project this chat is in") }
        scopes.append("\"people\" for facts about a person the user works with, with their name in \"person\"")
        let rule = outside
            ? "\nThis text was written from what other people said or wrote, so it says nothing about the user's own preferences: never use scope \"me\".\n"
            : ""
        let current = notes.map { "<notes file=\"\($0.0)\">\n\($0.1.isEmpty ? "(none)" : $0.1)\n</notes>" }.joined(separator: "\n")
        // The text is `prompts/memory-reflection.md`. The scope list, the rule for outside text and the notes are built here.
        return Prompts.render(id: "memory-reflection", [
            "pet": petName, "kind": kind, "scopes": scopes.joined(separator: "; "), "rule": rule, "notes": current, "input": input,
            "maxLength": String(MemoryNote.maxLength), "maxNotes": String(maxNotes),
        ])
    }

    /// The first JSON object in an answer, also when the agent wrapped it in a code fence or a sentence.
    package static func jsonObject(in answer: String) -> [String: Any]? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8))) as? [String: Any]
    }

    /// The notes the agent proposed. Nil when the answer is not the notes object; entries without a known scope or text are skipped.
    package static func parse(_ answer: String) -> [Proposal]? {
        guard let notes = jsonObject(in: answer)?["notes"] as? [Any] else { return nil }
        return notes.compactMap { raw in
            guard let entry = raw as? [String: Any], let scope = (entry["scope"] as? String).flatMap({ MemoryScope(rawValue: $0.lowercased()) }),
                  let text = entry["text"] as? String else { return nil }
            return Proposal(scope: scope, text: text, person: entry["person"] as? String,
                            replaces: (entry["replaces"] as? [Any] ?? []).compactMap { $0 as? String })
        }
    }

    /// Why a proposal is not saved, or nil.
    package static func refusal(_ proposal: Proposal, outside: Bool, hasProject: Bool) -> String? {
        if outside, proposal.scope == .me { return "outside text may not write me.md" }
        if outside, !proposal.replaces.isEmpty { return "outside text may not replace notes" }
        if proposal.replaces.count > MemoryNote.maxForget { return "replaces more than \(MemoryNote.maxForget) notes" }
        if proposal.scope == .project, !hasProject { return "no project" }
        if proposal.scope == .people, MemoryNote.personName(proposal.person) == nil { return "no person" }
        return nil
    }

    /// The links an answer names. An entry without two names or a type that is not a short snake_case verb is skipped.
    package static func parseLinks(_ answer: String) -> [(from: String, type: String, to: String)] {
        guard let links = jsonObject(in: answer)?["links"] as? [Any] else { return [] }
        return links.compactMap { raw in
            guard let entry = raw as? [String: Any], let from = entry["from"] as? String, let to = entry["to"] as? String,
                  let type = (entry["type"] as? String)?.lowercased(), (2...24).contains(type.count),
                  type.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_") }),
                  !from.trimmingCharacters(in: .whitespaces).isEmpty, !to.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (from, type, to)
        }
    }

    /// The merges an answer proposes: the claim refs (`claim_<hex>`) and the sentence that replaces them. Nil when the answer is not the merges object.
    package static func parseMerges(_ answer: String) -> [(ids: [String], text: String)]? {
        guard let merges = jsonObject(in: answer)?["merges"] as? [Any] else { return nil }
        return merges.compactMap { raw in
            guard let entry = raw as? [String: Any], let text = entry["text"] as? String, let ids = entry["ids"] as? [Any] else { return nil }
            return (ids.compactMap { $0 as? String }, text)
        }
    }

    // MARK: Agent

    /// The app's runner: the agent from Settings on a restricted backend in `~/.ironpet/scratch/memory`, every permission refused, with
    /// a three-minute limit. Its turns count as Memory in the Usage tab.
    package static func agentRunner(prompt: String, reader: Reader, spawner: ProcessSpawner) async -> Result<String, RunError> {
        guard let agent = AgentCatalog.agent(id: reader.agent) else {
            return .failure(RunError("the agent \"\(reader.agent)\" is not available. Pick another in Settings → Memory."))
        }
        let workspace = Paths.root.appendingPathComponent("scratch/memory")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let backend = ACPBackend(agent: agent, spawner: spawner)
        backend.restricted = true
        backend.usageFeature = .memory
        backend.onPermission = { _, respond in respond(.deny("Ghost's memory pass only answers")) }
        let turn = ACPTurn(prompt: prompt, preamble: nil, workspace: workspace, resume: nil, model: reader.model, images: [], files: [])
        let result = Answer()
        let task = Task { @MainActor in
            await backend.runTurn(turn) { event in
                switch event {
                case .assistant(let chunk): result.answer += chunk
                case .finished(let error): result.finish(error.map { .failure(RunError($0)) } ?? .success(result.answer))
                case .needsSignIn: result.finish(.failure(RunError("\(agent.name) needs you to sign in. Open it in the chat once.")))
                case .needsRuntime: result.finish(.failure(RunError("\(agent.name) needs Node 22 or Bun. Open it in the chat once.")))
                default: break
                }
            }
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            result.finish(.failure(RunError("the agent did not answer within \(Int(timeout)) seconds")))
        }
        let value = await result.wait()
        watchdog.cancel()
        task.cancel()
        backend.cancel()
        backend.shutdown()
        return value
    }

    /// One answer, delivered once, whichever of the turn and the watchdog ends first.
    @MainActor
    private final class Answer {
        var answer = ""
        private var value: Result<String, RunError>?
        private var continuation: CheckedContinuation<Result<String, RunError>, Never>?

        func finish(_ result: Result<String, RunError>) {
            guard value == nil else { return }
            value = result
            continuation?.resume(returning: result)
            continuation = nil
        }

        func wait() async -> Result<String, RunError> {
            if let value { return value }
            return await withCheckedContinuation { continuation = $0 }
        }
    }
}
