import Foundation

/// The agent process the supervisor runs for one agent: that agent's chat. Stopping it shuts the agent's CLI down. The chat's
/// threads are on disk, so a stopped agent loses nothing, and a new process for the same agent lists them again.
@MainActor
package final class ChatAgentProcess: AgentProcess {
    package let session: ChatSession
    private let end: () -> Void
    package var onCrash: (@MainActor () -> Void)?

    package init(session: ChatSession, end: @escaping () -> Void) {
        self.session = session
        self.end = end
        session.onAgentCrash = { [weak self] in self?.onCrash?() }
    }

    package func stop() {
        session.onAgentCrash = nil
        end()
    }

    package func adopts(_ launch: AgentLaunch) -> Bool {
        session.agent.id == launch.cli && session.model == launch.model && session.instructions == launch.instructions
    }
}

/// The chats of the agents that run on this node, one `ChatSession` and one `ChatAPI` each, and the way a call finds the right one.
/// Agent 1's chat is the one the app always had, so it is given to the hub, not made by it. Every other agent's chat is made when its
/// process starts and dropped when it stops, and nothing on disk is touched either way.
@MainActor
package final class AgentChats: AgentProcessLauncher {
    /// Fires before a chat is added or removed.
    package let changes = ChangeSignal()
    private let registry: AgentRegistry?
    private let defaultChat: ChatAPI
    private var others: [String: (session: ChatSession, api: ChatAPI)] = [:]
    /// Makes the chat for an agent other than agent 1. The Mac app passes one that wires speech, approvals and the spawner.
    package var makeSession: @MainActor (String) -> ChatSession
    /// Called with a new chat's API right after it is made, so the host can give it its event bus and background permissions.
    package var configure: (ChatAPI, ChatSession) -> Void = { _, _ in }
    /// Called with an agent's id after its chat is dropped, so the host can unhook what it wired to that chat.
    package var onStopped: ((String) -> Void)?
    /// The bus a new chat publishes its events on.
    package weak var events: APIEventBus?

    package init(defaultChat: ChatAPI, registry: AgentRegistry?, makeSession: @escaping @MainActor (String) -> ChatSession = { ChatSession(restore: true, agentID: $0) }) {
        self.defaultChat = defaultChat
        self.registry = registry
        self.makeSession = makeSession
    }

    /// The agents whose chat is running now, agent 1 first.
    package var runningAgents: [String] { [AgentOwner.defaultID] + others.keys.sorted() }

    /// The chat of a running agent. Nil and empty are agent 1. An agent no record has is `notFound`; one that exists but is disabled is
    /// `unavailable`, since it has no process to answer.
    package func api(for agentID: String?) throws -> ChatAPI {
        let id = AgentOwner.id(agentID)
        if id == AgentOwner.defaultID { return defaultChat }
        if let found = others[id] { return found.api }
        let record = try AgentOwner.resolve(id, registry: registry)
        if let enabled = registry?.get(record)?.enabled, !enabled { throw APIError.unavailable("agent \"\(id)\" is disabled") }
        throw APIError.unavailable("agent \"\(id)\" is not running")
    }

    /// The agent voice goes to and the only one that speaks its replies aloud: the one the user selected last, or agent 1 when that agent
    /// is disabled, deleted or has no running chat. Without a registry it is agent 1.
    package var activeAgentID: String {
        guard let registry else { return AgentOwner.defaultID }
        let id = registry.activeAgentID
        return runningAgents.contains(id) ? id : AgentOwner.defaultID
    }

    /// Makes an agent the active one. The agent must exist and be enabled.
    package func select(active agentID: String) throws {
        let id = AgentOwner.id(agentID)
        guard let registry else {
            if id == AgentOwner.defaultID { return }
            throw APIError.notFound("no agent with id \"\(id)\"")
        }
        try registry.select(active: id)
    }

    /// Whether this agent's replies are read aloud as they finish. Only the active agent's are; the others show as text.
    package func speaksReplies(_ agentID: String?) -> Bool { AgentOwner.id(agentID) == activeAgentID }

    package func session(for agentID: String?) -> ChatSession? {
        let id = AgentOwner.id(agentID)
        return id == AgentOwner.defaultID ? defaultSession : others[id]?.session
    }

    private var defaultSession: ChatSession { defaultChat.chatSession }

    /// Gives the chats started later the same record ids as agent 1's chat has.
    package func setRecords(_ refs: RecordRefs) {
        recordRefs = refs
        for (_, found) in others { found.api.records = refs }
    }

    private var recordRefs: RecordRefs?

    /// Answers an approval in whichever running chat holds it. False when none does.
    @discardableResult
    package func decide(id: UUID, allow: Bool) -> Bool {
        for agent in runningAgents {
            guard let session = session(for: agent), session.approvals.contains(where: { $0.id == id }) else { continue }
            session.decide(id: id, allow: allow)
            return true
        }
        return false
    }

    // MARK: Starting and stopping

    package func launch(_ launch: AgentLaunch) throws -> AgentProcess {
        let id = AgentOwner.id(launch.agentID)
        if id == AgentOwner.defaultID {
            let session = defaultSession
            if let registry { session.attach(registry: registry) }
            return ChatAgentProcess(session: session) { [weak session] in session?.stopAgentProcess() }
        }
        let session: ChatSession
        if let existing = others[id]?.session {
            session = existing
        } else {
            session = makeSession(id)
            let api = ChatAPI(session: session, files: defaultChat.fileIntake)
            api.registry = registry
            api.records = recordRefs ?? defaultChat.records
            session.events = events
            changes.send()
            others[id] = (session, api)
            configure(api, session)
        }
        if let registry { session.attach(registry: registry) }
        return ChatAgentProcess(session: session) { [weak self] in self?.drop(id) }
    }

    private func drop(_ id: String) {
        guard let found = others[id] else { return }
        changes.send()
        found.session.persistForRelaunch()
        found.session.shutdown()
        others[id] = nil
        onStopped?(id)
    }
}
