import XCTest
import IronPetKit
@testable import IronPet
@testable import IronPetCore

/// Several agents at once, through the API: each agent's chat is its own, the supervisor runs one process per enabled agent, and
/// disabling an agent keeps its history. The agents' CLIs are scripted `turnRunner`s, so no process starts.
@MainActor
final class SeveralAgentsTests: XCTestCase {
    private var events: APIEventBus!
    private var registry: AgentRegistry!
    private var api: IronPetAPI!
    private var supervisor: AgentSupervisor!
    private var agentA: ChatSession!
    private var agentB: AgentRecord!
    private var threadsBefore: URL!
    private var threads: URL!
    private var service: AutomationService!
    /// What each agent's scripted CLI received, and the way to answer each turn, by agent id.
    private var turns: [String: [ACPTurn]] = [:]
    private var deliver: [String: [(AgentEvent) -> Void]] = [:]

    override func setUp() async throws {
        TestMemory.isolate()
        threadsBefore = ThreadStore.directory
        threads = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-several-\(UUID().uuidString)")
        ThreadStore.directory = threads
        events = APIEventBus()
        registry = AgentRegistry(database: APITestSupport.memoryDatabase())
        agentB = try registry.create(name: "Bunny", pet: "/tmp/bunny.png", agentCli: "claude", model: "opus", instructions: "Answer in one line.")
        turns = [:]
        deliver = [:]
        agentA = ChatSession(restore: false)
        agentA.workspace = FileManager.default.temporaryDirectory
        script(agentA, AgentOwner.defaultID)
        api = APITestSupport.makeAPI(events: events, automations: [job("a-chat", owner: nil), job("b-chat", owner: agentB.id)], chat: agentA, agents: registry,
                                     configureAutomations: { [unowned self] in service = $0 })
        api.chats.makeSession = { [unowned self] id in
            let session = ChatSession(restore: false, agentID: id)
            session.workspace = FileManager.default.temporaryDirectory
            script(session, id)
            return session
        }
        // The real launcher starts a chat; the supervisor sees it through `AgentChats`.
        supervisor = AgentSupervisor(registry: registry, launcher: api.chats)
        supervisor.reconcile()
    }

    override func tearDown() async throws {
        supervisor.stopAll()
        ThreadStore.directory = threadsBefore
        try? FileManager.default.removeItem(at: threads)
    }

    private func job(_ id: String, owner: String?) -> Automation {
        Automation(id: id, name: id, trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: "Check the mail", session: "new", report: "chat"), createdBy: "user", agentId: owner)
    }

    private func script(_ session: ChatSession, _ id: String) {
        session.turnRunner = { [unowned self] turn, onEvent in
            turns[id, default: []].append(turn)
            deliver[id, default: []].append(onEvent)
        }
    }

    private func settle() async { for _ in 0..<8 { await Task.yield() } }

    private func rpc(_ method: String, _ params: [String: Any]? = nil) async throws -> [String: Any] {
        let dispatcher = RPCDispatcher(api: api)
        var object: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { object["params"] = params }
        let raw = await dispatcher.handle(line: try JSONSerialization.data(withJSONObject: object),
                                          connection: RPCConnection(deviceID: "test", name: "test", kind: .cli, connection: .inProcess))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    // MARK: S2, no mixing

    func testTwoAgentsHoldConversationsAtTheSameTimeWithoutMixingMessagesSessionsOrThreads() async throws {
        let toA = try await api.chat(for: nil).send(SendChatRequest(text: "question for A"))
        let toB = try await api.chat(for: agentB.id).send(SendChatRequest(text: "question for B"))
        XCTAssertEqual(toA.outcome, .sent)
        XCTAssertEqual(toB.outcome, .sent)
        await settle()
        XCTAssertEqual(turns[AgentOwner.defaultID]?.map(\.prompt).count, 1)
        XCTAssertEqual(turns[agentB.id]?.count, 1)
        XCTAssertTrue(turns[AgentOwner.defaultID]?.first?.prompt.contains("question for A") == true)
        XCTAssertTrue(turns[agentB.id]?.first?.prompt.contains("question for B") == true)
        XCTAssertFalse(turns[agentB.id]?.first?.prompt.contains("question for A") == true)

        // Both are mid-turn at once. Replies arrive interleaved.
        deliver[agentB.id]?[0](.session("thread-b"))
        deliver[AgentOwner.defaultID]?[0](.session("thread-a"))
        deliver[agentB.id]?[0](.assistant("answer from B"))
        deliver[AgentOwner.defaultID]?[0](.assistant("answer from A"))
        deliver[agentB.id]?[0](.finished(error: nil))
        deliver[AgentOwner.defaultID]?[0](.finished(error: nil))
        await settle()

        func assistantTexts(_ id: String?) async throws -> [String] {
            try await api.chat(for: id).messages().compactMap { if case .assistant(let text) = $0.kind { text } else { nil } }
        }
        let a = try await assistantTexts(nil)
        let b = try await assistantTexts(agentB.id)
        XCTAssertEqual(a, ["answer from A"])
        XCTAssertEqual(b, ["answer from B"])

        let aThreads = try await api.chat.threads(agentId: nil)
        let bThreads = try await api.chat.threads(agentId: agentB.id)
        XCTAssertEqual(aThreads.map(\.id), ["thread-a"])
        XCTAssertEqual(bThreads.map(\.id), ["thread-b"])
        XCTAssertEqual(bThreads.first?.agentId, agentB.id)
        XCTAssertEqual(Set(aThreads.map(\.id)).intersection(bThreads.map(\.id)), [])
    }

    func testTheWireListsDisjointThreadsForEachAgentAndRoutesEveryChatCall() async throws {
        _ = try await api.chat(for: agentB.id).send(SendChatRequest(text: "hi B"))
        _ = try await api.chat(for: nil).send(SendChatRequest(text: "hi A"))
        await settle()
        deliver[agentB.id]?[0](.session("thread-b"))
        deliver[agentB.id]?[0](.finished(error: nil))
        deliver[AgentOwner.defaultID]?[0](.session("thread-a"))
        deliver[AgentOwner.defaultID]?[0](.finished(error: nil))
        await settle()

        func ids(_ response: [String: Any]) -> [String] { (response["result"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        let listA = try await rpc("chat.threads")
        let listB = try await rpc("chat.threads", ["agentId": agentB.id])
        XCTAssertEqual(ids(listA), ["thread-a"])
        XCTAssertEqual(ids(listB), ["thread-b"])

        // The MCP tool lists the same disjoint threads.
        func mcpIDs(_ agent: String) async throws -> [String] {
            let value = try await ChatMCP.call("chat_threads_list", ["agentId": agent], api: api.chat, agent: nil).get()
            return ((value as? [String: Any])?["threads"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        let mcpA = try await mcpIDs(AgentOwner.defaultID)
        let mcpB = try await mcpIDs(agentB.id)
        XCTAssertEqual(mcpA, ["thread-a"])
        XCTAssertEqual(mcpB, ["thread-b"])

        let snapshotB = try await rpc("chat.snapshot", ["agentId": agentB.id])
        let result = try XCTUnwrap(snapshotB["result"] as? [String: Any])
        let messages = try XCTUnwrap(result["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["text"] as? String)?.contains("hi B") == true || "\($0)".contains("hi B") })
        XCTAssertFalse("\(messages)".contains("hi A"))

        // A send over the wire reaches only the named agent's CLI.
        let sent = try await rpc("chat.send", ["text": "second for B", "agentId": agentB.id, "files": [], "uploads": []])
        XCTAssertEqual((sent["result"] as? [String: Any])?["outcome"] as? String, "sent", "\(sent)")
        await settle()
        XCTAssertEqual(turns[agentB.id]?.count, 2)
        XCTAssertEqual(turns[AgentOwner.defaultID]?.count, 1)

        let unknown = try await rpc("chat.snapshot", ["agentId": "agent_nope"])
        XCTAssertEqual(((unknown["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String, "not_found")
    }

    func testAnAgentsEventsCarryItsId() async throws {
        var seen: [APIEvent] = []
        let subscription = events.subscribe { seen.append($0) }
        defer { subscription.cancel() }
        _ = try await api.chat(for: agentB.id).send(SendChatRequest(text: "hello"))
        _ = try await api.chat(for: nil).send(SendChatRequest(text: "hello"))
        let chatEvents = seen.filter { $0.kind == .chatItem || $0.kind == .chatState }
        XCTAssertTrue(chatEvents.contains { $0.agentId == agentB.id })
        XCTAssertTrue(chatEvents.contains { $0.agentId == nil }, "agent 1's events carry no agent id, as before")
        let note = RPCDispatcher.notification(for: try XCTUnwrap(chatEvents.first { $0.agentId == agentB.id }))
        if case .object(let fields) = note.params { XCTAssertEqual(fields["agentId"], .string(agentB.id)) } else { XCTFail("no params") }
    }

    func testAutomationsPostOnlyToTheirOwnersChat() async throws {
        let chatA = try XCTUnwrap(api.chats.session(for: nil))
        let chatB = try XCTUnwrap(api.chats.session(for: agentB.id))
        // The same wiring the app does for each chat.
        service.postNotice = { [weak chatA] kind, title, text, triggers in chatA?.postSystemNotice(kind: kind, text: text, title: title, triggersTurn: triggers) }
        service.agentChats[agentB.id] = .init(postNotice: { [weak chatB] kind, title, text, triggers in
            chatB?.postSystemNotice(kind: kind, text: text, title: title, triggersTurn: triggers)
        })
        service.runSession = { automation, _, _ in .success("answer from \(automation.id)") }

        _ = await service.call("run_now", ["id": "b-chat"], by: "user")
        for _ in 0..<40 where !chatB.items.contains(where: { "\($0.kind)".contains("answer from b-chat") }) { await settle() }
        XCTAssertTrue(chatB.items.contains { "\($0.kind)".contains("answer from b-chat") }, "B's automation reports to B's chat")
        XCTAssertFalse(chatA.items.contains { "\($0.kind)".contains("b-chat") }, "agent 1's chat hears nothing of it")

        _ = await service.call("run_now", ["id": "a-chat"], by: "user")
        for _ in 0..<40 where !chatA.items.contains(where: { "\($0.kind)".contains("answer from a-chat") }) { await settle() }
        XCTAssertTrue(chatA.items.contains { "\($0.kind)".contains("answer from a-chat") })
        XCTAssertFalse(chatB.items.contains { "\($0.kind)".contains("answer from a-chat") })
    }

    // MARK: S1 and S3 through the real launcher

    func testEachEnabledAgentHasItsOwnChatProcessLaunchedFromItsRecord() {
        XCTAssertEqual(Set(supervisor.running.keys), [AgentOwner.defaultID, agentB.id])
        XCTAssertEqual(supervisor.running[agentB.id], AgentLaunch(agentID: agentB.id, name: "Bunny", cli: "claude", model: "opus", instructions: "Answer in one line."))
        let chatB = api.chats.session(for: agentB.id)
        XCTAssertEqual(chatB?.agent.id, "claude")
        XCTAssertEqual(chatB?.model, "opus")
        XCTAssertEqual(chatB?.instructions, "Answer in one line.")
        XCTAssertEqual(api.chats.runningAgents, [AgentOwner.defaultID, agentB.id])
    }

    func testAnAgentsInstructionsGoWithTheFirstTurnOfANewSession() async throws {
        _ = try await api.chat(for: agentB.id).send(SendChatRequest(text: "hello"))
        await settle()
        let preamble = try XCTUnwrap(turns[agentB.id]?.first?.preamble)
        XCTAssertTrue(preamble.contains("Answer in one line."))
        _ = try await api.chat(for: nil).send(SendChatRequest(text: "hello"))
        await settle()
        XCTAssertFalse(turns[AgentOwner.defaultID]?.first?.preamble?.contains("Answer in one line.") == true)
    }

    func testDisablingAnAgentStopsItsChatAndKeepsItsHistoryOnDisk() async throws {
        _ = try await api.chat(for: agentB.id).send(SendChatRequest(text: "remember this"))
        await settle()
        deliver[agentB.id]?[0](.session("thread-b"))
        deliver[agentB.id]?[0](.assistant("noted"))
        deliver[agentB.id]?[0](.finished(error: nil))
        await settle()
        let before = try await api.chat.threads(agentId: agentB.id)
        XCTAssertEqual(before.map(\.id), ["thread-b"])

        try registry.update(agentB.id, AgentRecordPatch(enabled: false))
        supervisor.reconcile()
        XCTAssertNil(supervisor.running[agentB.id])
        XCTAssertNil(api.chats.session(for: agentB.id), "its chat is gone")
        XCTAssertThrowsError(try api.chat(for: agentB.id)) { XCTAssertEqual(($0 as? APIError)?.code, .unavailable) }
        XCTAssertFalse(AgentPetSet.slots(for: registry.list()).contains { $0.agentID == agentB.id }, "no pet to show")
        let whileOff = try await api.chat.threads(agentId: agentB.id)
        XCTAssertEqual(whileOff.map(\.id), ["thread-b"], "its threads stay on disk and stay listed by agent")
        XCTAssertNotNil(ThreadStore.load("thread-b"))

        try registry.update(agentB.id, AgentRecordPatch(enabled: true))
        supervisor.reconcile()
        XCTAssertNotNil(supervisor.running[agentB.id])
        let again = try await api.chat(for: agentB.id).threads()
        XCTAssertEqual(again.map(\.id), ["thread-b"], "enabling it lists its previous threads again")
    }

    func testAnAgentsAutomationsStayWhenItIsDisabled() async throws {
        try registry.update(agentB.id, AgentRecordPatch(enabled: false))
        supervisor.reconcile()
        let kept = try api.automations.list(agentId: agentB.id)
        XCTAssertTrue(kept.contains { $0.id == "b-chat" })
    }

    // MARK: S4, the agents API

    func testCreateUpdateDisableEnableAndDeleteOverTheAPIMoveTheSupervisor() async throws {
        let records = try XCTUnwrap(api.agentRecords)
        let created = try await rpc("agent.create", ["name": "Cat", "agentCli": "codex", "model": "gpt", "instructions": "Be kind."])
        let id = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual((created["result"] as? [String: Any])?["number"] as? Int, 3)
        supervisor.reconcile()
        XCTAssertEqual(supervisor.running[id]?.cli, "codex")

        _ = try await rpc("agent.update", ["id": id, "name": "Kitty", "model": "gpt-5"])
        supervisor.reconcile()
        XCTAssertEqual(supervisor.running[id]?.name, "Kitty", "a changed configuration restarts the agent")
        XCTAssertEqual(supervisor.running[id]?.model, "gpt-5")

        _ = try await rpc("agent.update", ["id": id, "enabled": false])
        supervisor.reconcile()
        XCTAssertNil(supervisor.running[id])
        XCTAssertEqual(try records.get(id).enabled, false)
        _ = try await rpc("agent.update", ["id": id, "enabled": true])
        supervisor.reconcile()
        XCTAssertNotNil(supervisor.running[id])

        let deleted = try await rpc("agent.delete", ["id": id])
        XCTAssertNil(deleted["error"])
        supervisor.reconcile()
        XCTAssertNil(supervisor.running[id])
        XCTAssertThrowsError(try records.get(id)) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }

        let agentOne = try await rpc("agent.delete", ["id": AgentOwner.defaultID])
        XCTAssertEqual(((agentOne["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String, "invalid")
        let unknown = try await rpc("agent.update", ["id": "agent_nope", "name": "x"])
        XCTAssertEqual(((unknown["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String, "not_found")
    }

    func testDeletingAnAgentThatOwnsAnEnabledAutomationIsRefusedAndNothingIsLost() async throws {
        let records = try XCTUnwrap(api.agentRecords)
        XCTAssertThrowsError(try records.delete(agentB.id)) { XCTAssertEqual(($0 as? APIError)?.code, .conflict) }
        XCTAssertNotNil(registry.get(agentB.id))
        _ = await service.call("delete", ["id": "b-chat"], by: "user")
        try records.delete(agentB.id)
        XCTAssertNil(registry.get(agentB.id))
    }

    func testMCPCreatesUpdatesAndDeletesAgents() async throws {
        let records = try XCTUnwrap(api.agentRecords)
        let created = try XCTUnwrap(try AgentMCP.call("agents_create", ["name": "Fox", "agentCli": "claude"], api: records).get() as? [String: Any])
        let id = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(created["enabled"] as? Bool, true)
        let updated = try XCTUnwrap(try AgentMCP.call("agents_update", ["id": id, "enabled": false, "model": "opus"], api: records).get() as? [String: Any])
        XCTAssertEqual(updated["enabled"] as? Bool, false)
        XCTAssertEqual(updated["model"] as? String, "opus")
        let cleared = try XCTUnwrap(try AgentMCP.call("agents_update", ["id": id, "model": ""], api: records).get() as? [String: Any])
        XCTAssertNil(cleared["model"])
        _ = try AgentMCP.call("agents_delete", ["id": id], api: records).get()
        if case .success = AgentMCP.call("agents_get", ["id": id], api: records) { XCTFail("deleted agent still found") }
        if case .success = AgentMCP.call("agents_delete", ["id": AgentOwner.defaultID], api: records) { XCTFail("agent 1 deleted") }
        if case .success = AgentMCP.call("agents_update", ["id": "agent_nope"], api: records) { XCTFail("unknown agent updated") }
    }

    // MARK: S6, who is asking

    func testAnApprovalAndAQuestionCarryTheAskingAgentsIdAndName() async throws {
        let chatB = try XCTUnwrap(api.chats.session(for: agentB.id))
        chatB.handlePermission(ACPToolCall(id: "t1", title: "Run tests", kind: "execute", rawInput: ["command": "npm test"]), respond: { _ in })
        chatB.handleElicitation(ElicitationForm(message: "Which branch?", fields: []), respond: { _ in })
        let chatBAPI = try api.chat(for: agentB.id)
        let approvals = await chatBAPI.approvals()
        let forms = await chatBAPI.forms()
        XCTAssertEqual(approvals.first?.agentId, agentB.id)
        XCTAssertEqual(approvals.first?.agentName, "Bunny")
        XCTAssertEqual(forms.first?.agentId, agentB.id)
        XCTAssertEqual(forms.first?.agentName, "Bunny")
        let aApprovals = await api.chat.approvals()
        XCTAssertTrue(aApprovals.isEmpty, "agent 1's chat has no approval of B's")

        let wire = try await rpc("chat.snapshot", ["agentId": agentB.id])
        let snapshot = try XCTUnwrap(wire["result"] as? [String: Any])
        let card = try XCTUnwrap((snapshot["approvals"] as? [[String: Any]])?.first)
        XCTAssertEqual(card["agentId"] as? String, agentB.id)
        XCTAssertEqual(card["agentName"] as? String, "Bunny")
    }

    func testTheHubAnswersAnApprovalInTheChatThatHoldsIt() async throws {
        let chatB = try XCTUnwrap(api.chats.session(for: agentB.id))
        var answered: [Bool] = []
        chatB.handlePermission(ACPToolCall(id: "t1", title: "Run tests", kind: "execute"), respond: { answered.append($0.allow) })
        let id = try XCTUnwrap(chatB.approvals.first?.id)
        XCTAssertTrue(api.chats.decide(id: id, allow: true))
        XCTAssertEqual(answered, [true])
        XCTAssertFalse(api.chats.decide(id: UUID(), allow: true))
    }

    func testTheAgentNameInTheSessionAndTheBubbleHeading() {
        let chatB = api.chats.session(for: agentB.id)
        XCTAssertEqual(chatB?.agentDisplayName, "Bunny")
        XCTAssertEqual(ChatViewModel.heading("Run tests", agent: "Bunny", showsAgent: true), "Bunny: Run tests")
        XCTAssertEqual(ChatViewModel.heading("Run tests", agent: "Bunny", showsAgent: false), "Run tests", "one agent: the card reads as it did")
        XCTAssertEqual(ChatViewModel.heading("Run tests", agent: nil, showsAgent: true), "Run tests")
    }

    // MARK: S5, the window's switcher and the pets

    func testTheSwitcherInAChatWindowListsEnabledAgentsAndOpensTheOneThatIsPicked() async throws {
        let model = ChatViewModel(api: api.chat, voiceAPI: api.voice, events: events, persists: false)
        model.agentRecords = { [registry] in registry!.list() }
        var opened: [String] = []
        model.onPickAgent = { opened.append($0) }
        XCTAssertTrue(model.switcher.isVisible)
        XCTAssertEqual(model.switcher.choices.map(\.name), ["Ghost", "Bunny"])
        model.pickAgent(agentB.id)
        model.pickAgent(AgentOwner.defaultID)
        XCTAssertEqual(opened, [agentB.id], "picking the agent already shown does nothing")

        try registry.update(agentB.id, AgentRecordPatch(enabled: false))
        XCTAssertFalse(model.switcher.isVisible, "with one agent left there is nothing to switch")
        model.pickAgent(agentB.id)
        XCTAssertEqual(opened, [agentB.id])
    }

    func testAChatWindowOnlyFollowsItsOwnAgentsEvents() async throws {
        let modelB = ChatViewModel(api: try api.chat(for: agentB.id), voiceAPI: api.voice, events: events, persists: false)
        modelB.agentName = "Bunny"
        _ = try await api.chat(for: nil).send(SendChatRequest(text: "only for A"))
        await settle()
        await modelB.settle()
        XCTAssertTrue(modelB.items.isEmpty, "A's message does not appear in B's window")
        _ = try await api.chat(for: agentB.id).send(SendChatRequest(text: "only for B"))
        await settle()
        await modelB.settle()

        XCTAssertTrue(modelB.items.contains { "\($0.kind)".contains("only for B") })
        XCTAssertFalse(modelB.items.contains { "\($0.kind)".contains("only for A") })
    }

    // MARK: S8, one agent

    func testWithOnlyAgentOneThereIsOneChatAndNothingElseRuns() throws {
        try registry.update(agentB.id, AgentRecordPatch(enabled: false))
        supervisor.reconcile()
        XCTAssertEqual(api.chats.runningAgents, [AgentOwner.defaultID])
        XCTAssertEqual(Array(supervisor.running.keys), [AgentOwner.defaultID])
        XCTAssertEqual(AgentPetSet.slots(for: registry.list()).map(\.agentID), [AgentOwner.defaultID])
        XCTAssertTrue(try api.chat(for: nil) === api.chat, "agent 1's chat is the one the app always used")
        XCTAssertTrue(try api.chat(for: "") === api.chat)
    }
}
