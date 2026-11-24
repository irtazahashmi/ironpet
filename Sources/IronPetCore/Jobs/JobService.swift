import Foundation

/// The part of an agent process a job needs. `ACPBackend` is the real one; tests script their own.
@MainActor
package protocol JobAgent: AnyObject {
    var onPermission: ((ACPToolCall, @escaping (ApprovalDecision) -> Void) -> Void)? { get set }
    func runTurn(_ turn: ACPTurn, onEvent: @escaping (AgentEvent) -> Void) async
    func cancel()
    func shutdown()
}

extension ACPBackend: JobAgent {}

package struct JobError: Error, LocalizedError {
    package init(message: String) {
        self.message = message
    }

    package let message: String
    package var errorDescription: String? { message }
}

/// Runs background jobs: at most `maxRunning` at once, the rest in line. Each job gets its own agent process in its
/// folder. the agent's own mode decides what it asks. A request that is not a read or another call ironpet always allows waits for Allow
/// in a bubble. A task tracks every job, the transcript is saved as a thread, and the state is kept in `ironpet.db`, so
/// a job that was running when ironpet quit shows as interrupted on the next launch.
@MainActor
package final class JobService: ObservableObject {
    package nonisolated static let migrations: [Database.Migration] = [
        .init(500, "jobs: background jobs", sql: """
            CREATE TABLE jobs(id TEXT PRIMARY KEY, title TEXT NOT NULL, prompt TEXT NOT NULL, folder TEXT NOT NULL, agent TEXT NOT NULL,
                              model TEXT, thread TEXT, task TEXT, state TEXT NOT NULL, last_step TEXT, summary TEXT, error TEXT,
                              created REAL NOT NULL, started REAL, ended REAL) WITHOUT ROWID;
            CREATE INDEX jobs_by_created ON jobs(created);
            """),
    ]

    /// Finished jobs older than this are deleted at launch.
    package static var retention: TimeInterval { TimeInterval(ConfigStore.shared.config.jobs.retentionDays * 86_400) }
    /// Jobs kept in memory for `jobs_list`, newest first.
    package static let listed = 50
    /// Who job changes are recorded as in a task's history.
    package static let taskAuthor = "agent:job"
    /// A job started by voice waits this long after the pet has said what it started, so "cancel that" stops it before it
    /// has done anything.
    package static let voiceHold: TimeInterval = 5
    /// The longest a voice job waits for the pet to finish speaking, should voice mode never release it.
    package static let voiceHoldLimit: TimeInterval = 60

    /// Newest first: the active jobs and the latest finished ones.
    @Published package private(set) var jobs: [Job] = []

    /// The agent and model a new job runs with: the chat's.
    package var currentAgent: () -> (agent: ACPAgent, model: String?)? = { nil }
    package var maxRunning: () -> Int = { ConfigStore.shared.config.jobs.maxRunning }
    /// How long a stopped job's turn may take to end after `session/cancel` before its process is closed.
    package var stopGrace: TimeInterval = 5
    /// One agent turn longer than this fails the job, so a stuck agent can't hold a slot forever.
    /// Set by tests. Nil reads `jobs.turnTimeoutMinutes`.
    package var turnTimeout: TimeInterval?
    package var turnTimeoutMinutes: () -> Int = { ConfigStore.shared.config.jobs.turnTimeoutMinutes }
    /// True while the chat runs a turn of its own on this session (a thread id). A job must not start a second process on it.
    package var sessionBusy: (String) -> Bool = { _ in false }
    /// Starts the agent's process. `AppDelegate` sets the Mac one.
    package var spawner: ProcessSpawner = UnsupportedProcessSpawner()
    package lazy var makeAgent: (ACPAgent, Job) -> JobAgent = { [weak self] agent, job in
        let backend = ACPBackend(agent: agent, spawner: self?.spawner ?? UnsupportedProcessSpawner())
        backend.usageFeature = .jobs
        backend.mcpServers = MCPEndpoint.jobScoped(ACPBackend.defaultMCPServers())
        // Memory notes the job saves name the job and default to its folder.
        backend.mcpCaller = MemoryMCP.jobCaller + job.id
        // Nobody is watching a job to fill in a form, so the agent is told no and carries on.
        backend.onElicitation = { _, respond in respond(.decline) }
        return backend
    }
    /// The text a job's first turn starts with, before the request.
    package var preamble: (Job) -> String = { job in
        JobService.instructions(job) + "\n\n"
            + MemoryPreamble.build(store: FileMemoryStore.shared, workspace: URL(fileURLWithPath: job.folder), firstMessage: job.prompt, keepsTasks: false)
    }
    /// Where a request from a job waits for an answer: an alert, the Mac's bubble and notification, Telegram and the phone. The app
    /// replaces it with the shared one.
    package var permissions = BackgroundPermissions()
    /// Every change to a job, for the Agents section and the bubbles.
    package var onChange: (Job) -> Void = { _ in }
    /// A job saved its transcript, so the chat can reload its history list and the open thread.
    package var onThreadSaved: (ChatThread) -> Void = { _ in }

    /// How long a voice job waits once released, and at most before. `voiceHold` and `voiceHoldLimit` in the app; tests
    /// shorten them.
    package var voiceHoldSeconds = JobService.voiceHold
    package var voiceHoldLimit = JobService.voiceHoldLimit

    private let database: Database
    private let tasks: TaskStore?
    private let now: () -> Date
    private var runs: [String: Run] = [:]
    /// Jobs started by voice in this run of the app. Not stored: after a restart they are interrupted anyway.
    private var voiceJobs: Set<String> = []
    /// Voice jobs still inside their hold, with the timer that ends it.
    private var held: [String: Task<Void, Never>] = [:]
    /// Held jobs whose short hold has not started yet: the pet is still answering.
    private var unreleased: Set<String> = []

    /// A job's live state while it holds an agent process.
    private final class Run {
        let agent: JobAgent
        var transcript: TranscriptRecorder
        var followUps: [String] = []
        var stopRequested = false

        init(agent: JobAgent, transcript: TranscriptRecorder) {
            self.agent = agent
            self.transcript = transcript
        }
    }

    package init(database: Database, tasks: TaskStore?, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.tasks = tasks
        self.now = now
        prune()
        interruptLeftovers()
        jobs = load()
    }

    package var unavailable: String? { database.unavailableReason }

    package func job(_ id: String) -> Job? { jobs.first { $0.id == id } }
    package func job(thread: String) -> Job? { jobs.first { $0.thread == thread } }
    package var running: [Job] { jobs.filter { $0.state == .running || $0.state == .needsApproval } }

    // MARK: Operations

    package func isFromVoice(_ id: String) -> Bool { voiceJobs.contains(id) }
    package func isHeld(_ id: String) -> Bool { held[id] != nil }

    /// Stops the newest voice job that is still waiting out its hold, for "cancel that". Nil when there is none.
    package func cancelHeldVoiceJob() -> Job? {
        guard let job = jobs.first(where: { held[$0.id] != nil && $0.state == .queued }) else { return nil }
        return try? stop(job.id)
    }

    /// The pet has said what it started: held voice jobs run `voiceHoldSeconds` from now.
    package func releaseVoiceHolds() {
        for id in unreleased { hold(id, for: voiceHoldSeconds) }
        unreleased = []
    }

    private func hold(_ id: String, for seconds: TimeInterval) {
        held[id]?.cancel()
        held[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, held.removeValue(forKey: id) != nil else { return }
            unreleased.remove(id)
            pump()
        }
    }

    private func holdForVoice(_ id: String) {
        voiceJobs.insert(id)
        unreleased.insert(id)
        hold(id, for: voiceHoldLimit)
    }

    private func release(_ id: String) {
        held.removeValue(forKey: id)?.cancel()
        unreleased.remove(id)
    }

    /// Starts a job in `folder`, or queues it when `maxRunning` jobs already run. Creates its task at once. A job from
    /// voice mode is held until `releaseVoiceHolds` and `voiceHoldSeconds` after it.
    @discardableResult
    package func start(title: String, prompt: String, folder: URL, fromVoice: Bool = false) throws -> Job {
        let title = title.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw JobError(message: "title is required: a few words saying what the job does") }
        guard title.count <= Job.titleLimit else { throw JobError(message: "title is at most \(Job.titleLimit) characters") }
        guard !prompt.isEmpty else { throw JobError(message: "prompt is required: the full instructions for the agent that does the work") }
        guard prompt.count <= Job.promptLimit else { throw JobError(message: "prompt is at most \(Job.promptLimit) characters") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JobError(message: "\(folder.path) is not a folder")
        }
        guard let (agent, model) = currentAgent() else { throw JobError(message: "no agent is available to run the job") }
        var job = Job(id: Job.makeID(), title: title, prompt: prompt, folder: folder.standardizedFileURL.path, agent: agent.id,
                      model: model, created: now())
        if let tasks {
            let task = try? tasks.create(title: title, notes: "Background job \(job.id) in \(folder.lastPathComponent).",
                                         status: .inProgress, source: .agent, sourceRef: job.id, by: Self.taskAuthor)
            job.task = task?.id
        }
        if fromVoice { holdForVoice(job.id) }
        jobs.insert(job, at: 0)
        trim()
        save(job)
        onChange(job)
        pump()
        return self.job(job.id) ?? job
    }

    /// Sends another message to a job. A running job gets it after its current turn; a finished one starts again in the same
    /// session; from voice mode it is held first, like a new voice job.
    @discardableResult
    package func followUp(_ id: String, message: String, fromVoice: Bool = false) throws -> Job {
        guard let job = job(id) else { throw JobError(message: "no job with id \"\(id)\"") }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw JobError(message: "message is empty") }
        guard message.count <= Job.promptLimit else { throw JobError(message: "message is at most \(Job.promptLimit) characters") }
        if let run = runs[id] {
            run.followUps.append(message)
            return job
        }
        if job.state == .queued {
            pendingFollowUps[id, default: []].append(message)
            return job
        }
        guard let thread = job.thread else { throw JobError(message: "the job ended before its agent session started; start a new job instead") }
        guard !sessionBusy(thread) else {
            throw JobError(message: "the chat is using this job's session right now; the message can go there instead")
        }
        pendingFollowUps[id, default: []].append(message)
        update(id) { job in
            job.state = .queued
            job.error = nil
            job.started = nil
            job.ended = nil
        }
        if let task = job.task, tasks?.task(task)?.status != .inProgress {
            _ = try? tasks?.update(task, status: .inProgress, note: "Follow-up: \(String(message.prefix(200)))", by: Self.taskAuthor)
        }
        if fromVoice { holdForVoice(id) }
        pump()
        return self.job(id) ?? job
    }

    /// Stops a job. A queued one never starts; a running one gets `session/cancel` and its process is closed.
    @discardableResult
    package func stop(_ id: String) throws -> Job {
        guard let job = job(id) else { throw JobError(message: "no job with id \"\(id)\"") }
        guard job.state.isActive else { return job }
        if let run = runs[id] {
            run.stopRequested = true
            denyApprovals(id)
            cancel(id, run)
        } else {
            pendingFollowUps[id] = nil
            release(id)
            finish(id, state: .stopped, note: "Stopped before it started.")
        }
        return self.job(id) ?? job
    }

    /// Closes every job's agent process, at quit. The jobs show as interrupted on the next launch.
    package func shutdownAll() {
        for (id, run) in runs {
            run.stopRequested = true
            denyApprovals(id)
            run.agent.shutdown()
        }
    }

    private func denyApprovals(_ id: String) {
        permissions.end(owner: id)
    }

    /// Sends `session/cancel`, and closes the process if the turn has not ended `stopGrace` later: an agent that is still
    /// starting, or stuck, ignores the cancel.
    private func cancel(_ id: String, _ run: Run) {
        run.agent.cancel()
        Task { [weak self, weak run] in
            guard let grace = self?.stopGrace else { return }
            try? await Task.sleep(for: .seconds(grace))
            guard let self, let run, runs[id] === run else { return }
            run.agent.shutdown()
        }
    }

    /// The last few transcript lines of a job, for `jobs_get`: reply text and tool rows, newest last.
    package func recentSteps(_ id: String, limit: Int = 8) -> [String] {
        let items = runs[id]?.transcript.items ?? job(id)?.thread.flatMap(ThreadStore.load)?.items ?? []
        return items.suffix(limit).compactMap { item in
            switch item.kind {
            case .user(let text): return "Prompt: " + String(text.prefix(300))
            case .assistant(let text): return String(text.prefix(600))
            case .tool(let summary, let ok): return "Tool: \(summary)" + (ok == false ? " (failed)" : "")
            case .error(let text): return "Error: " + text
            default: return nil
            }
        }
    }

    // MARK: Running

    private var pendingFollowUps: [String: [String]] = [:]

    /// Starts queued jobs, oldest first, while there are free slots.
    private func pump() {
        let limit = max(1, maxRunning())
        while runs.count < limit, let next = jobs.last(where: { $0.state == .queued && held[$0.id] == nil }) {
            launch(next)
        }
    }

    private func launch(_ job: Job) {
        guard let agent = AgentCatalog.agent(id: job.agent) else {
            return finish(job.id, state: .failed, error: "The agent \(job.agent) is not available any more.")
        }
        let resumed = job.thread.flatMap(ThreadStore.load)
        let run = Run(agent: makeAgent(agent, job), transcript: TranscriptRecorder(items: resumed?.items ?? []))
        run.followUps = pendingFollowUps.removeValue(forKey: job.id) ?? []
        runs[job.id] = run
        let id = job.id
        run.agent.onPermission = { [weak self] call, respond in self?.permission(id, call, respond) ?? respond(.deny("The job ended")) }
        update(id) { job in
            job.state = .running
            job.started = job.started ?? self.now()
        }
        Task { [weak self] in await self?.drive(id, run: run, agent: agent, resume: job.thread) }
    }

    /// Runs the first prompt (or, for a job started again, the first follow-up), then each follow-up in turn.
    private func drive(_ id: String, run: Run, agent: ACPAgent, resume: String?) async {
        guard let job = job(id) else { return }
        var prompt: String? = resume == nil ? job.prompt : (run.followUps.isEmpty ? nil : run.followUps.removeFirst())
        var outcome: String?? = .none
        while let text = prompt {
            let turn = ACPTurn(prompt: text, preamble: resume == nil && outcome == nil ? preamble(job) : nil,
                               workspace: URL(fileURLWithPath: job.folder), resume: self.job(id)?.thread, model: job.model,
                               images: [], files: [])
            run.transcript.beginTurn(.init(kind: .user(text), origin: ChatSession.jobOrigin))
            saveThread(id, run: run)
            let error = await turnResult(id, run: run, turn: turn, agentName: agent.name)
            outcome = .some(error)
            saveThread(id, run: run)
            // A follow-up the user sent still runs after a failed turn; it may be the fix ("try again with Node 22").
            if run.stopRequested || error != nil && run.followUps.isEmpty { break }
            prompt = run.followUps.isEmpty ? nil : run.followUps.removeFirst()
        }
        denyApprovals(id)
        run.agent.shutdown()
        runs[id] = nil
        let answer = run.transcript.answer
        if run.stopRequested {
            finish(id, state: .stopped, note: "Stopped by the user.")
        } else if case .some(.some(let error)) = outcome {
            finish(id, state: .failed, error: error)
        } else {
            finish(id, state: .done, summary: AgentSession.firstSentence(answer))
        }
        pump()
    }

    /// One turn. Returns the error that ended it, or nil.
    private func turnResult(_ id: String, run: Run, turn: ACPTurn, agentName: String) async -> String? {
        var failure: String?
        let timeout = turnTimeout ?? TimeInterval(max(1, turnTimeoutMinutes()) * 60)
        let watchdog = Task { [weak self, weak run] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, let run else { return }
            failure = "The agent did not finish within \(max(1, Int(timeout / 60))) minutes."
            cancel(id, run)
        }
        defer { watchdog.cancel() }
        await run.agent.runTurn(turn) { [weak self] event in
            guard let self else { return }
            // Stopped while the agent was starting: the prompt is in flight now, so the cancel can reach it.
            if run.stopRequested { return run.agent.cancel() }
            run.transcript.record(event)
            switch event {
            case .session(let session):
                update(id) { $0.thread = session }
                linkTask(id, thread: session)
                saveThread(id, run: run)
            case .toolStarted, .toolUpdated:
                if let step = run.transcript.lastStep, job(id)?.lastStep != step { update(id) { $0.lastStep = step } }
            case .finished(let error):
                if let error { failure = failure ?? error }
            case .needsSignIn:
                failure = "\(agentName) needs you to sign in. Open it in the chat once, then start the job again."
            case .needsRuntime:
                failure = "\(agentName) needs Node 22 or Bun. Open it in the chat once to set that up."
            default:
                break
            }
        }
        if let failure { run.transcript.append(.init(kind: .error(failure))) }
        return failure
    }

    /// Reads and ironpet's own tools are allowed. Any other request the agent sends becomes an alert with the agent's own options,
    /// and the job waits for the answer. After `jobs.permissionTimeoutMinutes` the agent gets its reject option and the job's task
    /// records the timeout.
    private func permission(_ id: String, _ call: ACPToolCall, _ respond: @escaping (ApprovalDecision) -> Void) {
        guard let run = runs[id], let job = job(id) else { return respond(.deny("The job ended")) }
        if run.stopRequested { return respond(.deny("The user stopped this job")) }
        switch ApprovalRules.policy(for: call) {
        case .allow:
            respond(.allow)
        case .ask(let title, _):
            permissions.ask(owner: id, source: "Job \"\(job.title)\"", call: call, respond: { [weak self] decision in
                respond(decision)
                guard let self, permissions.pending(owner: id).isEmpty, self.job(id)?.state == .needsApproval else { return }
                update(id) { job in
                    job.state = .running
                    job.waitingFor = nil
                }
            }, timedOut: { [weak self] line in
                guard let self, let task = self.job(id)?.task else { return }
                _ = try? tasks?.update(task, status: nil, note: line, by: Self.taskAuthor)
            })
            update(id) { job in
                job.state = .needsApproval
                job.waitingFor = title
            }
        }
    }

    /// Raises a job's waiting requests again, say after their bubble was closed without an answer.
    package func showApprovals(_ id: String) { permissions.reshow(owner: id) }

    private func finish(_ id: String, state: JobState, summary: String? = nil, error: String? = nil, note: String? = nil) {
        update(id) { job in
            job.state = state
            job.ended = self.now()
            job.waitingFor = nil
            job.summary = summary ?? (state == .done ? job.summary : nil)
            job.error = error
        }
        guard let job = job(id), let task = job.task, let tasks, tasks.task(task) != nil else { return }
        switch state {
        case .done:
            _ = try? tasks.close(task, note: "Job finished" + (summary.map { ": \($0)" } ?? "."), by: Self.taskAuthor)
        case .failed:
            _ = try? tasks.update(task, status: .needsYou, note: "Job failed: \(error ?? "unknown error")", by: Self.taskAuthor)
        case .stopped:
            _ = try? tasks.close(task, note: note ?? "Stopped.", by: Self.taskAuthor)
        default:
            break
        }
    }

    private func linkTask(_ id: String, thread: String) {
        guard let job = job(id), let task = job.task, let item = tasks?.task(task),
              !item.links.contains(where: { $0.kind == .thread && $0.ref == thread }) else { return }
        _ = try? tasks?.update(task, links: item.links + [TaskLink(kind: .thread, ref: thread, label: "Job transcript")], by: Self.taskAuthor)
    }

    private func saveThread(_ id: String, run: Run) {
        guard let job = job(id), let thread = job.thread else { return }
        let saved = ChatThread(id: thread, title: job.title, workspace: job.folder, updatedAt: now(), items: run.transcript.items,
                               agent: job.agent, job: job.id)
        ThreadStore.save(saved)
        onThreadSaved(saved)
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        change(&job)
        guard job != jobs[index] else { return }
        jobs[index] = job
        save(job)
        onChange(job)
    }

    /// A job that was queued or running when ironpet quit has no process any more. Its task goes back to the backlog.
    private func interruptLeftovers() {
        let active = JobState.allCases.filter(\.isActive).map(\.rawValue)
        let marks = Array(repeating: "?", count: active.count).joined(separator: ", ")
        let tasks = (try? database.read { db in
            try db.rows("SELECT task FROM jobs WHERE state IN (\(marks)) AND task IS NOT NULL", active)
        })?.compactMap { $0[0] as? String } ?? []
        try? database.write { db in
            try db.execute("UPDATE jobs SET state = ?, ended = ? WHERE state IN (\(marks))",
                           [JobState.interrupted.rawValue, now().timeIntervalSince1970] + active)
        }
        for task in tasks where self.tasks?.task(task)?.status == .inProgress {
            _ = try? self.tasks?.update(task, status: .backlog, note: "ironpet quit while this job was running. Ask Ghost to run it again.",
                                        by: Self.taskAuthor)
        }
    }

    /// Keeps the active jobs and the newest finished ones, `listed` in all.
    private func trim() {
        guard jobs.count > Self.listed else { return }
        var finished = Self.listed - jobs.filter(\.state.isActive).count
        jobs = jobs.filter { job in
            if job.state.isActive { return true }
            finished -= 1
            return finished >= 0
        }
    }

    // MARK: Storage

    private func save(_ job: Job) {
        do {
            try database.write { db in
                try db.execute("""
                    INSERT OR REPLACE INTO jobs(id, title, prompt, folder, agent, model, thread, task, state, last_step, summary, error,
                                                created, started, ended)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [job.id, job.title, job.prompt, job.folder, job.agent, job.model, job.thread, job.task, job.state.rawValue,
                          job.lastStep, job.summary, job.error, job.created.timeIntervalSince1970,
                          job.started?.timeIntervalSince1970, job.ended?.timeIntervalSince1970])
            }
        } catch {
            NSLog("ironpet: could not save job \(job.id): \(error.localizedDescription)")
        }
    }

    private func load() -> [Job] {
        let rows = (try? database.read { db in
            try db.rows("""
                SELECT id, title, prompt, folder, agent, model, thread, task, state, last_step, summary, error, created, started, ended
                FROM jobs ORDER BY created DESC LIMIT ?
                """, [Self.listed])
        }) ?? []
        return rows.compactMap { row in
            guard let id = row[0] as? String, let title = row[1] as? String, let prompt = row[2] as? String, let folder = row[3] as? String,
                  let agent = row[4] as? String, let state = (row[8] as? String).flatMap(JobState.init(rawValue:)),
                  let created = row[12] as? Double else { return nil }
            func date(_ value: Any?) -> Date? { (value as? Double).map(Date.init(timeIntervalSince1970:)) }
            return Job(id: id, title: title, prompt: prompt, folder: folder, agent: agent, model: row[5] as? String,
                       thread: row[6] as? String, task: row[7] as? String, state: state, lastStep: row[9] as? String,
                       summary: row[10] as? String, error: row[11] as? String, created: Date(timeIntervalSince1970: created),
                       started: date(row[13]), ended: date(row[14]))
        }
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.retention).timeIntervalSince1970
        try? database.write { try $0.execute("DELETE FROM jobs WHERE ended IS NOT NULL AND ended < ?", [cutoff]) }
    }

    // MARK: Instructions

    /// What the job's agent is told before the request: it runs unattended, and how to end.
    /// The text is `prompts/job-instructions.md`; the job's id, title and folder are filled in here.
    package nonisolated static func instructions(_ job: Job) -> String {
        Prompts.render(id: "job-instructions", ["id": job.id, "title": job.title, "folder": job.folder])
    }
}
