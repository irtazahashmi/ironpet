import Foundation

/// The scheduled task scan. Each run reads what is new since the last one: each chat's messages, each meeting summary and transcript
/// written since, and the screen captures when `tasks.scanScreen` and screen capture are on. It sends that text, with the open tasks and
/// the suggestions that already wait, to one agent, and files what the agent names as suggestions: new tasks, and changes to existing
/// ones (a note to append, done, who the task waits on). Nothing changes a task until the user presses Accept.
///
/// The reading and the agent call are the memory digest's (`ReflectionReading`, `ReflectionAgent`), and the rule for who may read
/// what is the same as `MemoryReflector`'s: a chat goes only to the agent that already had it, a meeting to the agent that wrote its
/// summary, and screen text to the digest agent, the chat's agent. The task list and the waiting suggestions go only to the digest
/// agent, since only it reads tasks through its tools. Another agent's batch can propose new tasks but never changes.
///
/// The agent runs restricted: no MCP servers, a scratch folder, every permission request refused. The text is data, never
/// instructions. An answer that is not the JSON object, or that names a task that does not exist, files nothing, and the cursors of
/// that batch stay, so the next run reads the same text again. Cursors live in `TaskStore`, so they survive a restart.
@MainActor
package final class TaskScanner {
    /// What one run did.
    package struct Outcome: Equatable {
        package init(filed: [String] = [], dropped: [String] = [], errors: [String] = [], batches: Int = 0, skipped: Bool = false) {
            self.filed = filed
            self.dropped = dropped
            self.errors = errors
            self.batches = batches
            self.skipped = skipped
        }

        /// The ids of the suggestions the run filed.
        package var filed: [String] = []
        package var dropped: [String] = []
        /// One line for each batch that failed. Its text is read again by the next run.
        package var errors: [String] = []
        /// How many times an agent was asked.
        package var batches = 0
        /// Nothing new to read, the scan is off, or another run was going.
        package var skipped = false
    }

    package typealias Runner = @MainActor (_ prompt: String, _ reader: ReflectionReader) async -> Result<String, ReflectionError>

    /// Most new tasks, and most changes, one batch may file.
    package static let maxNew = 10
    package static let maxUpdates = 10
    /// Most open tasks one prompt lists. The most recently changed come first.
    package static let maxListedTasks = 80
    /// The cursor row that says the chats and captures from before the first scan were marked as read.
    package static let seededKey = "seeded"
    static let screenKey = "screen"

    package let store: TaskStore
    package var runner: Runner
    package var config: () -> Config = { ConfigStore.shared.config }
    package var now: () -> Date = Date.init
    package var threads: (String) -> ChatThread? = ThreadStore.load
    package var recentThreads: () -> [ChatThread] = { ThreadStore.recent(limit: 50, automationLimit: 0) }
    /// Newest first, as `CaptureStore.recent` returns them.
    package var captures: () -> [StoredCapture] = { [] }
    /// The chat's agent, which reads the task list and the screen text.
    package var digestAgent: () -> String? = { nil }
    package var petName: () -> String = { ConfigStore.shared.config.pet.name }
    /// Reads a meeting's file. Replaced in tests.
    package var readFile: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    /// Called with the suggestions a batch filed, so the app can tell the user.
    package var onFiled: (([TaskSuggestion]) -> Void)?
    /// Called after a run filed suggestions or failed, so the UI can refresh.
    package var onChange: (() -> Void)?

    package private(set) var lastOutcome: Outcome?
    package private(set) var running = false
    /// Meeting summaries written since the last run, and the agent that wrote each.
    private var pendingMeetings: [(folder: URL, agent: String)] = []
    /// Bumped by `cancel`, so the answer of a run that started before it is thrown away.
    private var generation = 0

    /// `spawner` starts the default runner's agent. A `runner` passed in does not use it.
    package init(store: TaskStore, spawner: ProcessSpawner = UnsupportedProcessSpawner(), runner: Runner? = nil) {
        self.store = store
        self.runner = runner ?? { prompt, reader in
            await ReflectionAgent.run(prompt: prompt, reader: reader, spawner: spawner, scratch: "task-scan", feature: .taskScan,
                                      refusal: "Ghost's task scan only answers", settings: "Tasks", timeout: MemoryReflector.timeout)
        }
    }

    // MARK: Triggers

    /// A meeting summary was written. The next run reads it, with its transcript, by the agent that wrote it.
    package func meetingSummaryWritten(_ folder: URL, agent: String) {
        guard !pendingMeetings.contains(where: { $0.folder == folder }) else { return }
        pendingMeetings.append((folder, agent))
    }

    /// Once, at the first launch with the task scan: marks the chats and captures from before it as read, so turning it on does not
    /// send weeks of history to an agent and file a flood of suggestions.
    package func seedIfNeeded() {
        guard store.scanCursor(Self.seededKey) == nil else { return }
        var cursors: [(key: String, item: String)] = []
        for thread in recentThreads() {
            if let last = thread.items.last { cursors.append((Self.chatKey(thread.id), last.id.uuidString)) }
        }
        if let newest = captures().first { cursors.append((Self.screenKey, String(newest.id))) }
        cursors.append((Self.seededKey, "1"))
        store.setScanCursors(cursors)
    }

    /// Forget Everything, or the scan turned off: the run in flight files nothing and moves no cursor.
    package func cancel() {
        generation += 1
        pendingMeetings = []
    }

    // MARK: Reading

    /// One piece of new text with the cursors to move once it was read. `messages` is set for a chat.
    private struct Source {
        let heading: String
        /// The text, with the message tags built from the source's tag.
        let render: (_ tag: String) -> String
        let agent: String
        let ref: [String: Any]
        let messages: [String]
        let cursors: [(key: String, item: String)]
        var tag = ""
        var size: Int { render("S1").count + heading.count + 20 }
    }

    private static func chatKey(_ id: String) -> String { "chat:" + id }
    private static func meetingKey(_ folder: URL) -> String { "meeting:" + folder.path }

    private func sources(_ settings: Config) -> [Source] {
        let maxInput = settings.memory.reflectMaxInputChars
        let pet = petName()
        var result: [Source] = []
        for thread in recentThreads() where !thread.isAutomationRun && thread.job == nil && settings.memory.reader(for: thread.agent) != nil {
            let messages = ReflectionReading.unread(in: thread, after: store.scanCursor(Self.chatKey(thread.id)))
            guard !messages.isEmpty, let last = thread.items.last else { continue }
            // The tag of a line is the source's tag and the message's position, so an answer can point at one message.
            result.append(Source(heading: "A chat between the user and \(pet)",
                                 render: { tag in ReflectionReading.transcript(messages, petName: pet, maxInput: maxInput) { "[\(tag).\($0 + 1)]" } },
                                 agent: thread.agent,
                                 ref: ["thread": thread.id], messages: messages.map(\.id),
                                 cursors: [(Self.chatKey(thread.id), last.id.uuidString)]))
        }
        for meeting in pendingMeetings {
            let summary = readFile(meeting.folder.appendingPathComponent("summary.md"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let transcript = readFile(meeting.folder.appendingPathComponent("transcript.md"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !summary.isEmpty || !transcript.isEmpty else { continue }
            let key = Self.meetingKey(meeting.folder)
            let stamp = ReflectionReading.stamp(summary + "\n" + transcript)
            guard store.scanCursor(key)?.item != stamp, settings.memory.reader(for: meeting.agent) != nil else { continue }
            // The summary whole, up to half the budget, then the newest part of the transcript.
            let head = String(summary.prefix(maxInput / 2))
            let rest = max(0, maxInput - head.count - 40)
            var parts: [String] = []
            if !head.isEmpty { parts.append("Summary:\n" + head) }
            if !transcript.isEmpty, rest > 0 { parts.append("Transcript:\n" + String(transcript.suffix(rest))) }
            let text = parts.joined(separator: "\n\n")
            result.append(Source(heading: "A meeting the user recorded", render: { _ in text }, agent: meeting.agent,
                                 ref: ["meeting": meeting.folder.path], messages: [], cursors: [(key, stamp)]))
        }
        if settings.screenCapture.enabled, settings.tasks.scanScreen, let agent = digestAgent(), settings.memory.reader(for: agent) != nil {
            let fresh = ReflectionReading.freshCaptures(captures(), after: store.scanCursor(Self.screenKey)?.item)
            if let newest = fresh.first {
                let text = ReflectionReading.screenText(fresh, maxInput: maxInput)
                result.append(Source(heading: "Text on the user's screen, as captured while they worked",
                                     render: { _ in text }, agent: agent,
                                     ref: ["capture": String(newest.id)], messages: [], cursors: [(Self.screenKey, String(newest.id))]))
            }
        }
        return result
    }

    /// The sources of one agent, in groups that each fit in `maxInput` characters. A source never splits across groups.
    private func batches(_ sources: [Source], maxInput: Int) -> [[Source]] {
        var result: [[Source]] = []
        var used = 0
        for source in sources {
            let size = source.size
            if result.isEmpty || used + size > maxInput {
                result.append([])
                used = 0
            }
            result[result.count - 1].append(source)
            used += size
        }
        return result
    }

    // MARK: Running

    /// One scan. The caller schedules it. Returns what it filed, and why anything was left out.
    @discardableResult
    package func scan() async -> Outcome {
        let settings = config()
        guard !running, settings.tasks.scan else { return Outcome(skipped: true) }
        running = true
        defer { running = false }
        let started = generation
        var outcome = Outcome()
        let all = sources(settings)
        guard !all.isEmpty else {
            outcome.skipped = true
            return outcome
        }
        // Agents in the order their text first appears, so the run is the same each time for the same input.
        var agents: [String] = []
        for source in all where !agents.contains(source.agent) { agents.append(source.agent) }
        var failedMeetings: Set<URL> = []
        for agent in agents {
            guard let found = settings.memory.reader(for: agent) else { continue }
            let reader = ReflectionReader(agent: found.agent, model: found.model)
            for var batch in batches(all.filter { $0.agent == agent }, maxInput: settings.memory.reflectMaxInputChars) {
                for index in batch.indices { batch[index].tag = "S\(index + 1)" }
                let result = await run(batch, reader: reader, agent: agent, started: started)
                guard generation == started, config().tasks.scan else {
                    outcome.skipped = true
                    return outcome
                }
                outcome.batches += 1
                outcome.filed += result.filed
                outcome.dropped += result.dropped
                if let error = result.error {
                    outcome.errors.append(error)
                    for source in batch { if let folder = source.ref["meeting"] as? String { failedMeetings.insert(URL(fileURLWithPath: folder)) } }
                }
            }
        }
        // A meeting is read once. One whose batch failed stays queued, since its cursor did not move.
        pendingMeetings.removeAll { !failedMeetings.contains($0.folder) }
        lastOutcome = outcome
        if !outcome.filed.isEmpty || !outcome.errors.isEmpty { onChange?() }
        return outcome
    }

    private func run(_ batch: [Source], reader: ReflectionReader, agent: String, started: Int)
        async -> (filed: [String], dropped: [String], error: String?) {
        let settings = config()
        // The task list and the waiting suggestions go only to the agent that already reads tasks.
        let sharesTasks = digestAgent() == agent
        let open = sharesTasks ? Array(store.tasks.filter { $0.status != .done }.sorted { $0.updated > $1.updated }.prefix(Self.maxListedTasks)) : []
        let prompt = Self.prompt(batch: batch, open: open, pending: sharesTasks ? store.suggestions : [], petName: petName(), today: now())
        let answer = await runner(prompt, reader)
        guard generation == started, config().tasks.scan else { return ([], [], nil) }
        switch answer {
        case .failure(let failure):
            NSLog("ironpet: task scan failed: \(failure.message)")
            return ([], [], failure.message)
        case .success(let text):
            let proposals: Proposals
            switch Self.parse(text, knownTasks: Set(open.map(\.id))) {
            case .failure(let failure):
                NSLog("ironpet: task scan answer rejected: \(failure.message)")
                return ([], [], failure.message)
            case .success(let parsed):
                proposals = parsed
            }
            var dropped: [String] = []
            var drafts: [TaskSuggestion.Draft] = []
            for item in proposals.new.prefix(Self.maxNew) {
                var action: [String: Any] = ["id": "scan", "title": item.title]
                if let due = item.due { action["due"] = due }
                if let notes = item.notes { action["notes"] = notes }
                guard var draft = try? TaskSuggestion.Draft(action: action) else {
                    dropped.append("\(item.title) (not a usable task)")
                    continue
                }
                draft.waitingOn = item.waitingOn
                draft.sourceRef = sourceRef(item.source, batch: batch)
                draft.clarify = item.clarify
                drafts.append(draft)
            }
            var updates: [(update: TaskSuggestion.Update, sourceRef: String?)] = []
            for item in proposals.updates.prefix(Self.maxUpdates) {
                guard let target = open.first(where: { $0.id == item.task }) else { continue }
                updates.append((TaskSuggestion.Update(target: target.id, targetTitle: target.title, note: item.note, markDone: item.done,
                                                      waitingOn: item.waitingOn), sourceRef(item.source, batch: batch)))
            }
            let titles = Set(drafts.map { ActionItems.normalized($0.title) })
            let filedNew = store.suggest(scan: drafts)
            let filedUpdates = store.suggest(scanUpdates: updates)
            let kept = Set(filedNew.map { ActionItems.normalized($0.title) })
            dropped += titles.subtracting(kept).sorted().map { "\($0) (a task or suggestion with this title exists)" }
            // The batch was read in full, so its cursors move, also when the agent found nothing.
            store.setScanCursors(batch.flatMap(\.cursors))
            if !filedNew.isEmpty || !filedUpdates.isEmpty { onFiled?(filedNew + filedUpdates) }
            return ((filedNew + filedUpdates).map(\.id), dropped, nil)
        }
    }

    /// The `sourceRef` of a proposal: the chat thread and message, the meeting folder or the capture its tag names. Nil when the tag
    /// names nothing in this batch, so the suggestion gets the scan's plain reference instead of a wrong one.
    private func sourceRef(_ tag: String?, batch: [Source]) -> String? {
        guard let tag else { return nil }
        let parts = tag.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ".", maxSplits: 1).map(String.init)
        guard let head = parts.first, let source = batch.first(where: { $0.tag == head }) else { return nil }
        var ref: [String: Any] = source.ref
        ref["ref"] = "task-scan"
        ref["reason"] = "Found by the task scan"
        ref["at"] = ISO8601DateFormatter().string(from: now())
        if parts.count == 2, source.messages.isEmpty == false {
            let number = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
            if (1...source.messages.count).contains(number) { ref["message"] = source.messages[number - 1] }
        }
        return TaskRef.text(ref)
    }

    // MARK: Prompt and answer

    private static func prompt(batch: [Source], open: [TaskItem], pending: [TaskSuggestion], petName: String, today: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let tasks = open.map { task -> String in
            var line = "- \(task.id): \(TaskSuggestion.Draft.clean(task.title, limit: 120, newlines: false)) (\(task.status.rawValue))"
            if let waiting = task.waitingOn { line += ", waiting on \(waiting)" }
            return line
        }
        let waiting = pending.map { suggestion -> String in
            if let update = suggestion.update { return "- Update: \(update.targetTitle). \(update.summary)" }
            return "- \(TaskSuggestion.Draft.clean(suggestion.title, limit: 120, newlines: false))"
        }
        let input = batch.map { "<source tag=\"\($0.tag)\" kind=\"\($0.heading)\">\n\($0.render($0.tag))\n</source>" }.joined(separator: "\n")
        return Prompts.render(id: "task-scan", [
            "pet": petName, "today": day.string(from: today), "tasks": tasks.isEmpty ? "(none)" : tasks.joined(separator: "\n"),
            "pending": waiting.isEmpty ? "(none)" : waiting.joined(separator: "\n"), "input": input,
            "maxNew": String(maxNew), "maxUpdates": String(maxUpdates),
        ])
    }

    package struct NewProposal: Equatable {
        package var title: String
        package var due: String?
        package var notes: String?
        package var waitingOn: String?
        package var source: String?
        /// How the agent proposes to file it. A context outside the six or an unusable area is dropped, not the entry.
        package var clarify: TaskSuggestion.Clarify? = nil
    }

    package struct UpdateProposal: Equatable {
        package var task: String
        package var done: Bool
        package var waitingOn: String?
        package var note: String?
        package var source: String?
    }

    package struct Proposals: Equatable {
        package var new: [NewProposal] = []
        package var updates: [UpdateProposal] = []
    }

    /// The clarify fields of a new entry, checked by the same rules as labels. Nil when it proposes nothing usable.
    static func clarify(_ entry: [String: Any]) -> TaskSuggestion.Clarify? {
        let context = (entry["context"] as? String).flatMap { try? TaskContext.checked($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap(TaskContext.init(rawValue:))
        // Scan text comes from chats, meetings and the screen, so the area is cleaned like the title and notes.
        let area = (entry["area"] as? String).map { TaskSuggestion.Draft.clean($0, limit: TaskValidator.maxLabelValue, newlines: false) }
            .flatMap { try? TaskValidator.labels(["area": $0])["area"] }
        // Work someone else holds is a waiting-on task, not a someday idea.
        let waiting = (entry["waiting_on"] as? String).map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        let clarify = TaskSuggestion.Clarify(context: context, area: area, twoMinute: entry["two_minute"] as? Bool ?? false,
                                             someday: !waiting && (entry["someday"] as? Bool ?? false))
        return clarify.isEmpty ? nil : clarify
    }

    /// What the agent proposed. A failure when the answer is not the JSON object, when an entry has no title or task, or when an
    /// update names a task that is not in `knownTasks`. One bad entry rejects the whole answer, so a confused agent files nothing.
    package static func parse(_ answer: String, knownTasks: Set<String>) -> Result<Proposals, ReflectionError> {
        guard let object = ReflectionReading.jsonObject(in: answer), object["new"] is [Any] || object["updates"] is [Any] else {
            return .failure(ReflectionError("the agent did not answer with the task scan JSON"))
        }
        func text(_ value: Any?) -> String? {
            guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
            return string
        }
        var proposals = Proposals()
        for raw in object["new"] as? [Any] ?? [] {
            guard let entry = raw as? [String: Any], let title = text(entry["title"]) else {
                return .failure(ReflectionError("the agent filed a new task without a title"))
            }
            proposals.new.append(NewProposal(title: title, due: text(entry["due"]), notes: text(entry["notes"]),
                                             waitingOn: text(entry["waiting_on"]), source: text(entry["source"]), clarify: clarify(entry)))
        }
        for raw in object["updates"] as? [Any] ?? [] {
            guard let entry = raw as? [String: Any], let task = text(entry["task"]) else {
                return .failure(ReflectionError("the agent changed a task without naming it"))
            }
            guard knownTasks.contains(task) else {
                return .failure(ReflectionError("the agent named a task that does not exist: \(task)"))
            }
            proposals.updates.append(UpdateProposal(task: task, done: entry["done"] as? Bool ?? false, waitingOn: text(entry["waiting_on"]),
                                                    note: text(entry["note"]), source: text(entry["source"])))
        }
        return .success(proposals)
    }
}
