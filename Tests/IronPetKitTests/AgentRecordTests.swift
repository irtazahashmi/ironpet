import XCTest
@testable import IronPetKit

/// The agent list of a Mac that runs several agents, and the `agentId` query item of the chat calls.
final class AgentRecordTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    func paired() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    func testARecordWithoutEnabledIsEnabledAndOptionalFieldsStayNil() throws {
        let json = #"{"agents":[{"id":"agent_default","number":1,"name":"Ghost","agentCli":"claude","cliModels":{},"instructions":"","permissions":{},"created":"2026-11-01T10:00:00Z","updated":"2026-11-01T10:00:00Z"}]}"#
        let list = try WireJSON.makeDecoder().decode(AgentRecordListResponse.self, from: Data(json.utf8))
        let agent = try XCTUnwrap(list.agents.first)
        XCTAssertTrue(agent.enabled, "an older Mac leaves `enabled` out, and that means true")
        XCTAssertNil(agent.pet)
        XCTAssertNil(agent.model)
        XCTAssertTrue(agent.isDefault)
        XCTAssertNil(agent.chatAgentID, "agent 1 sends no agentId")
    }

    func testARecordReadsEnabledFalseAndAnotherAgentSendsItsId() throws {
        let json = #"{"agents":[{"id":"agent_3f9a","number":2,"name":"Fox","pet":"p-fox","agentCli":"codex","model":"gpt","enabled":false}]}"#
        let agent = try XCTUnwrap(try WireJSON.makeDecoder().decode(AgentRecordListResponse.self, from: Data(json.utf8)).agents.first)
        XCTAssertFalse(agent.enabled)
        XCTAssertEqual(agent.pet, "p-fox")
        XCTAssertEqual(agent.model, "gpt")
        XCTAssertEqual(agent.chatAgentID, "agent_3f9a")
    }

    func testAnUnreadableRecordIsSkippedAndTheRestStay() throws {
        let json = #"{"agents":[{"number":2},{"id":"agent_default","name":"Ghost"}]}"#
        let list = try WireJSON.makeDecoder().decode(AgentRecordListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(list.agents.map(\.id), ["agent_default"])
    }

    func testAgentRecordsReadsTheListAndAnOlderMacAnswers404() async throws {
        server.agentRecords = [RemoteAgentRecord(id: "agent_default", number: 1, name: "Ghost"), RemoteAgentRecord(id: "agent_2", number: 2, name: "Fox", enabled: false)]
        let list = try await paired().agentRecords()
        XCTAssertEqual(list.map(\.id), ["agent_default", "agent_2"])
        XCTAssertEqual(list.map(\.enabled), [true, false])

        server.agentRecords = nil
        do {
            _ = try await paired().agentRecords()
            XCTFail("a Mac without the route answers 404")
        } catch ClientError.api(let status, _, _) {
            XCTAssertEqual(status, 404)
        }
    }

    func testChatCallsCarryAgentIdOnlyWhenGiven() async throws {
        server.setAgentChat("agent_2", chat: RemoteChatSnapshot(title: "Fox chat", items: [RemoteChatItem(id: "f1", kind: "user", text: "hi fox")]),
                            threads: [RemoteChatThread(id: "fox-th", title: "Fox thread")])
        let client = paired()

        let main = try await client.chat(), fox = try await client.chat(agentId: "agent_2")
        let foxThreads = try await client.chatThreads(agentId: "agent_2"), mainThreads = try await client.chatThreads()
        let message = try await client.chatMessage(id: "f1", agentId: "agent_2")
        XCTAssertEqual(main.title, "Fix the login test")
        XCTAssertEqual(fox.title, "Fox chat")
        XCTAssertEqual(foxThreads.map(\.id), ["fox-th"])
        XCTAssertEqual(mainThreads.map(\.id), ["th-1", "th-2"])
        XCTAssertEqual(message.text, "hi fox")
        try await client.sendMessage(text: "yo", agentId: "agent_2")
        try await client.stopChat(agentId: "agent_2")
        try await client.openThread(id: "fox-th", agentId: "agent_2")
        try await client.newChat(agentId: "agent_2")
        try await client.decide(approval: "a1", allow: true, agentId: "agent_2")
        try await client.submit(form: "f1", agentId: "agent_2")
        try await client.skip(form: "f1", agentId: "agent_2")
        try await client.setChatOptions(RemoteChatOptionsChange(mode: "plan"), agentId: "agent_2")

        let queries = Dictionary(grouping: server.requests.filter { $0.path.hasPrefix("/v1/chat") }, by: \.line).mapValues { $0.map(\.query) }
        XCTAssertEqual(queries["GET /v1/chat/current"], ["", "agentId=agent_2"])
        XCTAssertEqual(queries["GET /v1/chat/threads"], ["agentId=agent_2", ""])
        for line in ["POST /v1/chat/current/messages", "POST /v1/chat/current/stop", "POST /v1/chat/open/fox-th", "POST /v1/chat/new", "POST /v1/chat/approvals/a1",
                     "POST /v1/chat/forms/f1/submit", "POST /v1/chat/forms/f1/skip", "PATCH /v1/chat/options", "GET /v1/chat/messages/f1"] {
            XCTAssertEqual(queries[line], ["agentId=agent_2"], line)
        }
    }

    func testAnEmptyAgentIdAddsNoQueryItem() {
        XCTAssertEqual(IronPetClient.agentQuery(nil), [])
        XCTAssertEqual(IronPetClient.agentQuery(""), [])
        XCTAssertEqual(IronPetClient.agentQuery("agent_2"), [URLQueryItem(name: "agentId", value: "agent_2")])
    }

    func testApprovalsAndFormsDecodeTheAgentTheyNameAndStayNilWithout() throws {
        let json = #"{"title":"t","approvals":[{"id":"a1","title":"Run","detail":"ls","agent_id":"agent_2","agent_name":"Fox"},{"id":"a2","title":"Run","detail":""}],"forms":[{"id":"f1","message":"m","fields":[],"agent_id":"agent_2","agent_name":"Fox"}]}"#
        let chat = try WireJSON.makeDecoder().decode(RemoteChatSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(chat.approvals.map(\.agentName), ["Fox", nil])
        XCTAssertEqual(chat.approvals.first?.agentId, "agent_2")
        XCTAssertEqual(chat.forms.first?.agentName, "Fox")
    }

    func testAChatEventDecodesItsAgentId() throws {
        let event = try WireJSON.makeDecoder().decode(RemoteEvent.self, from: Data(#"{"seq":4,"kind":"chat.item","id":"m1","agentId":"agent_2"}"#.utf8))
        XCTAssertEqual(event.agentId, "agent_2")
    }
}
