import XCTest
import IronPetKit
@testable import IronPetRemote

/// S7 (phone): the Mac runs several agents. The phone lists them, opens each agent's chat on its own model, and behaves as before
/// against a Mac that has no agent list.
@MainActor
final class AgentChatsTests: XCTestCase {
    var server: MockIronPetServer!
    var hub: AgentChatsModel!
    var main: ChatModel!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        server.chat = RemoteChatSnapshot(threadID: "th-main", title: "Ghost chat", items: [RemoteChatItem(id: "g-1", kind: "user", date: Date(), text: "hello ghost")])
        server.setAgentChat("agent_fox", chat: RemoteChatSnapshot(threadID: "th-fox", title: "Fox chat", items: [RemoteChatItem(id: "f-1", kind: "user", date: Date(), text: "hello fox")]),
                            threads: [RemoteChatThread(id: "fox-thread", title: "Fox only thread")])
    }

    override func tearDown() {
        hub?.stop()
        main?.stop()
        server.stop()
    }

    private func twoAgents() {
        server.agentRecords = [RemoteAgentRecord(id: defaultAgentID, number: 1, name: "Ghost"), RemoteAgentRecord(id: "agent_fox", number: 2, name: "Fox")]
    }

    private func start() async {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let network = NetworkHealth()
        let mainModel = ChatModel(client: client, events: events, network: network, onUnauthorized: {})
        main = mainModel
        hub = AgentChatsModel(client: client, events: events, network: network, main: mainModel,
                              makeChat: { ChatModel(client: client, events: events, network: network, agentId: $0, onUnauthorized: {}) }, onUnauthorized: {})
        main.start()
        hub.start()
        // A Mac with no agent list answers 404, which counts as a failed read: the model is done once it loaded or that refresh failed.
        await poll { (self.hub.loaded || self.hub.lastRefreshFailed) && self.main.snapshot != nil }
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func chatRequests(agent: String?) -> [MockIronPetServer.Recorded] {
        server.requests.filter { $0.path.hasPrefix("/v1/chat") && ($0.query.contains("agentId=\(agent ?? "")") == (agent != nil)) }
    }

    // (a) Two agents are listed, and each can be opened.
    func testTwoAgentsAreListed() async {
        twoAgents()
        server.agentRecords?.append(RemoteAgentRecord(id: "agent_owl", number: 3, name: "Owl", enabled: false))
        await start()
        XCTAssertTrue(hub.showsAgents)
        XCTAssertEqual(hub.listed.map(\.name), ["Ghost", "Fox", "Owl"])
        XCTAssertEqual(hub.listed.map(\.enabled), [true, true, false])
        XCTAssertEqual(hub.enabled.map(\.id), [defaultAgentID, "agent_fox"])

        hub.select("agent_owl")
        XCTAssertNil(hub.currentRecord.flatMap { $0.id == "agent_owl" ? $0 : nil }, "a disabled agent cannot be opened")
        XCTAssertTrue(hub.current === main)
    }

    // (b) Each agent's chat shows only its own threads and messages, and its calls carry its id.
    func testEachAgentShowsOnlyItsOwnChatAndSendsItsId() async {
        twoAgents()
        await start()
        XCTAssertTrue(hub.current === main, "agent 1 is shown first")
        hub.select("agent_fox")
        let fox = hub.current
        XCTAssertFalse(fox === main)
        XCTAssertEqual(fox.agentId, "agent_fox")
        await poll { fox.snapshot != nil }
        XCTAssertEqual(fox.title, "Fox chat")
        XCTAssertEqual(fox.items.map(\.id), ["f-1"])
        XCTAssertEqual(main.items.map(\.id), ["g-1"])

        await fox.loadThreads()
        await main.loadThreads()
        XCTAssertEqual(fox.threads.map(\.id), ["fox-thread"])
        XCTAssertEqual(main.threads.map(\.id), ["th-1", "th-2"])

        fox.draft = "ping fox"
        await fox.send()
        await poll { fox.items.contains { $0.text == "ping fox" } }
        let send = server.requests.last { $0.path == "/v1/chat/current/messages" }
        XCTAssertEqual(send?.query, "agentId=agent_fox")
        XCTAssertEqual(send?.json["text"] as? String, "ping fox")
        XCTAssertFalse(main.items.contains { $0.text == "ping fox" })

        XCTAssertTrue(chatRequests(agent: nil).allSatisfy { !$0.query.contains("agentId") })
        XCTAssertFalse(chatRequests(agent: "agent_fox").isEmpty)

        hub.select(nil)
        XCTAssertTrue(hub.current === main)
    }

    // (c) A Mac with no agent list shows agent 1 only and sends no agentId.
    func testAnOlderMacWithNoAgentListShowsAgentOneOnly() async {
        server.agentRecords = nil
        await start()
        XCTAssertTrue(hub.records.isEmpty)
        XCTAssertFalse(hub.showsAgents)
        XCTAssertTrue(hub.listed.isEmpty)
        XCTAssertTrue(hub.current === main)
        hub.select("agent_fox")
        XCTAssertTrue(hub.current === main, "an agent the Mac does not list is not opened")

        await main.loadThreads()
        main.draft = "hi"
        await main.send()
        await poll { self.main.items.contains { $0.text == "hi" } }
        XCTAssertFalse(chatRequests(agent: nil).isEmpty)
        XCTAssertTrue(server.requests.filter { $0.path.hasPrefix("/v1/chat") }.allSatisfy { !$0.query.contains("agentId") }, "no chat call names an agent")
        XCTAssertGreaterThanOrEqual(server.count("GET /v1/agent-records"), 1, "the phone asked, got 404 and went on")
    }

    // With one enabled agent the Chat tab is what it was: no picker, no second model.
    func testOneEnabledAgentShowsNoChoice() async {
        server.agentRecords = [RemoteAgentRecord(id: defaultAgentID, number: 1, name: "Ghost"), RemoteAgentRecord(id: "agent_fox", number: 2, name: "Fox", enabled: false)]
        await start()
        XCTAssertFalse(hub.showsAgents)
        XCTAssertTrue(hub.listed.isEmpty)
        XCTAssertTrue(hub.current === main)
        XCTAssertTrue(chatRequests(agent: "agent_fox").isEmpty, "no second chat is read")
    }

    // (d) A chat event of agent B changes agent B's model and leaves agent A's alone, and the other way round.
    func testAChatEventOfOneAgentDoesNotChangeTheOther() async {
        twoAgents()
        await start()
        hub.select("agent_fox")
        let fox = hub.current
        await poll { fox.snapshot != nil }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let mainReads = server.requests.filter { $0.line == "GET /v1/chat/current" && !$0.query.contains("agentId") }.count
        let mainItems = main.items

        server.postAgentMessage("agent_fox", id: "f-2", text: "fox says hi")
        _ = server.publish(RemoteEvent.chatState, agentId: "agent_fox")
        await poll { fox.items.contains { $0.id == "f-2" } }
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(fox.items.map(\.id), ["f-1", "f-2"])
        XCTAssertEqual(main.items, mainItems, "agent B's message is not in agent A's chat")
        XCTAssertEqual(server.requests.filter { $0.line == "GET /v1/chat/current" && !$0.query.contains("agentId") }.count, mainReads,
                       "agent B's chat.state does not make agent A read its chat again")

        let foxItems = fox.items
        server.streamChunk(item: "g-2", "ghost says hi")
        await poll { self.main.items.contains { $0.id == "g-2" } }
        XCTAssertEqual(fox.items, foxItems, "agent 1's event, which names no agent, is not agent B's")
    }
}
