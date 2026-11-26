import Foundation
import IronPetKit
import Observation

/// The agents of the Mac and one chat model for each of them. Agent 1 uses the model the app already had, so a Mac with one agent, or
/// one that predates the agent list, behaves as it did before. Each other agent has its own `ChatModel`: its own transcript, threads,
/// cache and outbox, and its own filter on the `agentId` of chat events.
@MainActor @Observable
final class AgentChatsModel: SocketModel {
    /// What `GET /v1/agent-records` last answered. Empty until it answered, and after a Mac that has no such route.
    private(set) var records: [RemoteAgentRecord] = []
    /// The agent whose chat the Chat tab shows. Nil is agent 1.
    private(set) var selectedID: String?
    /// Agent 1's chat.
    @ObservationIgnored let main: ChatModel
    @ObservationIgnored private let makeChat: (String) -> ChatModel
    @ObservationIgnored private var others: [String: ChatModel] = [:]

    init(client: IronPetClient, events: any EventSignalSource, network: NetworkHealth? = nil, main: ChatModel,
         makeChat: @escaping (String) -> ChatModel, onUnauthorized: @escaping () -> Void) {
        self.main = main
        self.makeChat = makeChat
        super.init(client: client, events: events, network: network, onUnauthorized: onUnauthorized)
    }

    /// The agents that run, in the Mac's order.
    var enabled: [RemoteAgentRecord] { records.filter(\.enabled) }

    /// True when the phone offers a choice of agent: the Mac runs more than one. With one enabled agent, or no list, the Chat tab is the
    /// single chat it always was.
    var showsAgents: Bool { enabled.count > 1 }

    /// The agents to list, with those the Mac turned off. They are listed but cannot be opened.
    var listed: [RemoteAgentRecord] { showsAgents ? records : [] }

    /// The chat the Chat tab shows now.
    var current: ChatModel { model(forAgent: showsAgents ? selectedID : nil) }

    /// The shown agent's record, nil for agent 1 on a Mac with no list.
    var currentRecord: RemoteAgentRecord? {
        guard showsAgents else { return nil }
        return records.first { selectedID == nil ? $0.isDefault : $0.id == selectedID }
    }

    /// Chats waiting for an answer, in every agent's chat. The Chat tab's badge.
    var waitingCount: Int {
        main.approvals.count + main.forms.count + others.values.reduce(0) { $0 + $1.approvals.count + $1.forms.count }
    }

    /// The chat model of an agent. Nil, `agent_default` and an id the Mac does not list give agent 1's.
    func model(forAgent id: String?) -> ChatModel {
        guard let id, id != defaultAgentID, records.contains(where: { $0.id == id }) else { return main }
        if let held = others[id] { return held }
        let made = makeChat(id)
        others[id] = made
        return made
    }

    /// Shows an agent's chat. A disabled or unknown agent is not opened.
    func select(_ id: String?) {
        guard showsAgents, let id, id != defaultAgentID else { selectedID = nil; return }
        guard records.contains(where: { $0.id == id && $0.enabled }) else { return }
        selectedID = id
        model(forAgent: id).start()
    }

    override func reload() async {
        if let list = await read({ try await self.client.agentRecords() }) {
            apply(list)
        } else if let error = lastError, !RequestRetry.isTransient(error) {
            // A Mac from before several agents answers 404, and an answer this app cannot read is no list either: agent 1 only.
            apply([])
        }
        // A transient failure keeps the list the phone already has.
    }

    private func apply(_ list: [RemoteAgentRecord]) {
        records = list
        if let selectedID, !list.contains(where: { $0.id == selectedID && $0.enabled }) || enabled.count < 2 { self.selectedID = nil }
        guard enabled.count > 1 else {
            for chat in others.values { chat.stop() }
            return
        }
        // Every running agent's chat is followed, so an approval another agent asks for shows on the tab before that chat is opened.
        for record in list where !record.isDefault {
            let chat = model(forAgent: record.id)
            if record.enabled { chat.start() } else { chat.stop() }
        }
    }

    override func stop() {
        for chat in others.values { chat.stop() }
        super.stop()
    }
}
