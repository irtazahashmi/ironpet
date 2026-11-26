import Foundation

/// A saved quick-chat thread. `id` is the agent's ACP session id and `workspace` its cwd, so a thread reopens with
/// `session/load`. Threads saved before ACP have no `agent` and are skipped.
package struct ChatThread: Codable, Identifiable {
    package init(
        id: String,
        title: String,
        workspace: String,
        updatedAt: Date,
        items: [ChatSession.Item],
        agent: String,
        automation: String? = nil,
        automationName: String? = nil,
        runs: Int? = nil,
        job: String? = nil,
        voice: Bool? = nil,
        session: String? = nil,
        previousSessions: [String]? = nil,
        handoff: String? = nil,
        agentId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.workspace = workspace
        self.updatedAt = updatedAt
        self.items = items
        self.agent = agent
        self.automation = automation
        self.automationName = automationName
        self.runs = runs
        self.job = job
        self.voice = voice
        self.session = session
        self.previousSessions = previousSessions
        self.handoff = handoff
        self.agentId = agentId
    }

    package let id: String
    package var title: String
    package var workspace: String
    package var updatedAt: Date
    package var items: [ChatSession.Item]
    /// The catalog id of the agent that owns the session.
    package var agent: String
    /// The id of the automation whose run this thread holds. Nil for a thread the user started.
    package var automation: String? = nil
    /// The automation's name when the run was recorded, shown in the thread list.
    package var automationName: String? = nil
    /// How many automation runs this thread holds. An `own` session starts a fresh thread after a limit.
    package var runs: Int? = nil
    /// The id of the background job whose transcript this thread holds (`JobService`).
    package var job: String? = nil
    /// True for a voice-mode conversation (`FrontDesk`).
    package var voice: Bool? = nil

    /// The agent session the thread runs on now. Nil means `id`, which is how a thread saved before rollover existed
    /// (and any thread that never rolled over) stores it. `id` itself never changes, so memory search hits stay valid.
    package var session: String? = nil
    /// Agent sessions the thread left at a rollover, oldest first. Their transcripts are deleted after the retention period.
    package var previousSessions: [String]? = nil
    /// Set between a rollover and the first turn of the new agent session: the context that turn carries. While it is
    /// set and `session` is nil, the thread has no agent session yet.
    package var handoff: String? = nil

    /// The id of the agent that owns the thread. Nil in a file saved before agents owned threads, which is agent 1's.
    package var agentId: String? = nil

    /// The owning agent's id, with a missing one read as agent 1.
    package var ownerAgentID: String { AgentOwner.id(agentId) }

    package var isAutomationRun: Bool { automation != nil }

    /// The agent session id this thread resumes, or nil when a rollover left it waiting for a fresh session.
    package var activeSession: String? { session ?? (handoff == nil ? id : nil) }
}

extension ChatThread {
    /// A thread reopened after the app quit: steps that were still running when it quit can't finish
    /// any more, so they show as failed instead of spinning forever.
    package func restoredAfterQuit() -> ChatThread {
        var thread = self
        thread.items = items.map { item in
            guard case .tool(let summary, ok: nil) = item.kind else { return item }
            var item = item
            item.kind = .tool(summary, ok: false)
            return item
        }
        return thread
    }
}

/// Persists threads as JSON files in `~/.ironpet/threads/`.
package enum ThreadStore {
    /// A variable so tests can point it at a temp folder.
    package nonisolated(unsafe) static var directory = Paths.root.appendingPathComponent("threads")
    /// Called after each save, for the memory index. Set once at launch on the main thread, before any thread is saved.
    package nonisolated(unsafe) static var didSave: ((ChatThread) -> Void)?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    package static func save(_ thread: ChatThread) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(thread).write(to: file(thread.id), options: .atomic)
            didSave?(thread)
        } catch {
            NSLog("ironpet: could not save thread \(thread.id): \(error)")
        }
    }

    package static func load(_ id: String) -> ChatThread? {
        (try? Data(contentsOf: file(id))).flatMap { try? decoder.decode(ChatThread.self, from: $0) }
    }

    /// Most recent first. Automation runs are capped at `automationLimit`, so an hourly job does not push the user's own
    /// threads out of the list.
    package static func recent(limit: Int = 15, automationLimit: Int = 5, agent: String? = nil) -> [ChatThread] {
        var automations = 0
        return all(agent: agent)
            .filter { thread in
                guard thread.isAutomationRun else { return true }
                automations += 1
                return automations <= automationLimit
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Voice-mode conversations, most recent first.
    package static func voice(limit: Int = 20) -> [ChatThread] {
        Array(all().filter { $0.voice == true }.prefix(limit))
    }

    /// Every thread, newest first. With `agent`, only the threads that agent owns.
    package static func all(agent: String? = nil) -> [ChatThread] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(ChatThread.self, from: $0) } }
            .filter { thread in agent.map { thread.ownerAgentID == AgentOwner.id($0) } ?? true }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Deletes this automation's oldest threads beyond the newest `keep`.
    package static func prune(automation id: String, keep: Int) {
        for thread in all().filter({ $0.automation == id }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: file(thread.id))
        }
    }

    /// The newest thread that holds runs of this automation.
    package static func latest(automation id: String) -> ChatThread? {
        all().first { $0.automation == id }
    }

    private static func file(_ id: String) -> URL {
        directory.appendingPathComponent("\(id.replacingOccurrences(of: "/", with: "_")).json")
    }
}
