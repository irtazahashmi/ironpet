import Foundation
import XCTest
import IronPetKit
@testable import IronPetCore

/// Chat threads, agent sessions and automations each have an owner agent. Everything written before owners existed belongs to agent 1, and
/// a list as one agent shows only that agent's things.
@MainActor
final class AgentOwnerTests: XCTestCase {
    private var directory: URL!
    private var threadsBefore: URL!

    override func setUp() async throws {
        try await super.setUp()
        TestMemory.isolate()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        threadsBefore = ThreadStore.directory
        ThreadStore.directory = directory.appendingPathComponent("threads")
    }

    override func tearDown() async throws {
        ThreadStore.directory = threadsBefore
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func requestLine(_ method: String, _ params: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { object["params"] = params }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func call(_ rig: ContractRig, _ method: String, _ params: [String: Any]? = nil) async throws -> [String: Any] {
        let raw = await rig.dispatcher.handle(line: requestLine(method, params), connection: rig.connection)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    private func ids(_ response: [String: Any]) -> [String] {
        (response["result"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    // MARK: S1, files written before owners existed

    /// The JSON a thread file holds in the build before owners: no `agentId`.
    private let oldThread = """
        {"agent":"cursor","id":"old-thread","items":[],"title":"Old chat","updatedAt":"2026-01-01T10:00:00Z","workspace":"/tmp/work"}
        """

    func testAThreadFileWithoutAnOwnerBelongsToAgentOneAndIsNotRewritten() throws {
        try FileManager.default.createDirectory(at: ThreadStore.directory, withIntermediateDirectories: true)
        let file = ThreadStore.directory.appendingPathComponent("old-thread.json")
        try Data(oldThread.utf8).write(to: file)

        let thread = try XCTUnwrap(ThreadStore.load("old-thread"))
        XCTAssertNil(thread.agentId)
        XCTAssertEqual(thread.ownerAgentID, "agent_default")
        XCTAssertEqual(ThreadStore.all().map(\.id), ["old-thread"], "listing with no agent returns what it returned before")
        XCTAssertEqual(ThreadStore.all(agent: "agent_default").map(\.id), ["old-thread"])
        XCTAssertEqual(ThreadStore.all(agent: "").map(\.id), ["old-thread"], "an empty id is agent 1")
        XCTAssertEqual(ThreadStore.all(agent: "agent_two").map(\.id), [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), oldThread, "reading does not rewrite the file")
    }

    func testAThreadSavedWithoutAnOwnerWritesNoOwnerField() throws {
        ThreadStore.save(ChatThread(id: "plain", title: "t", workspace: "/tmp", updatedAt: Date(), items: [], agent: "cursor"))
        let text = try String(contentsOf: ThreadStore.directory.appendingPathComponent("plain.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("agentId"))
        ThreadStore.save(ChatThread(id: "owned", title: "t", workspace: "/tmp", updatedAt: Date(), items: [], agent: "cursor", agentId: "agent_two"))
        XCTAssertTrue(try String(contentsOf: ThreadStore.directory.appendingPathComponent("owned.json"), encoding: .utf8).contains("\"agentId\":\"agent_two\""))
        XCTAssertEqual(ThreadStore.all(agent: "agent_two").map(\.id), ["owned"])
        XCTAssertEqual(ThreadStore.all(agent: "agent_default").map(\.id), ["plain"])
    }

    func testAnAutomationFileWithoutOwnersLoadsAsAgentOneAndIsNotRewritten() throws {
        let file = directory.appendingPathComponent("automations.json")
        let text = """
            {
              "automations" : [
                {
                  "action" : { "body" : "Have a glass of water.", "title" : "Drink some water", "type" : "bubble" },
                  "createdBy" : "user",
                  "enabled" : true,
                  "id" : "water",
                  "name" : "Drink water",
                  "presentation" : { "mood" : "drinking" },
                  "trigger" : { "clock" : "active", "minutes" : 45, "type" : "interval" }
                },
                {
                  "action" : { "digest" : "brief", "type" : "digest" },
                  "createdBy" : "user",
                  "enabled" : false,
                  "id" : "morning-brief",
                  "name" : "Morning brief",
                  "trigger" : { "times" : ["08:30"], "type" : "daily" }
                }
              ]
            }
            """
        try text.write(to: file, atomically: true, encoding: .utf8)
        let store = AutomationStore(paths: AutomationPaths(file: file, directory: directory.appendingPathComponent("automations")),
                                    defaults: { [] }, watch: false)
        XCTAssertNil(store.error)
        let water = try XCTUnwrap(store.automations.first { $0.id == "water" })
        XCTAssertNil(water.agentId)
        XCTAssertEqual(water.ownerAgentID, "agent_default")
        XCTAssertNil(try XCTUnwrap(store.automations.first { $0.id == "morning-brief" }).ownerAgentID, "a built-in has no owner")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text, "loading does not rewrite the file")
    }

    func testASessionNoHookAttributedBelongsToAgentOne() {
        let store = SessionStore()
        store.apply(HookEvent(source: .claude, name: "UserPromptSubmit", payload: ["session_id": "a", "prompt": "hi"], origin: SessionOrigin()))
        store.apply(HookEvent(source: .claude, name: "UserPromptSubmit", payload: ["session_id": "b", "prompt": "hi"], origin: SessionOrigin(),
                              agentId: "agent_two"))
        XCTAssertEqual(store.sessions["claude:a"]?.ownerAgentID, "agent_default")
        XCTAssertNil(store.sessions["claude:a"]?.agentId)
        XCTAssertEqual(store.sessions["claude:b"]?.ownerAgentID, "agent_two")
        XCTAssertEqual(store.ordered(agent: nil).count, 2, "no agent lists every session, as before")
        XCTAssertEqual(store.ordered(agent: "agent_default").map(\.id), ["claude:a"])
        XCTAssertEqual(store.ordered(agent: "agent_two").map(\.id), ["claude:b"])
    }

    // MARK: S3, chat threads

    func testChatThreadsListAsEachAgentAndAsTheUI() async throws {
        let rig = try ContractRig(seed: ["agentTwo"])
        let asUI = ids(try await call(rig, "chat.threads"))
        let asOne = ids(try await call(rig, "chat.threads", ["agentId": "agent_default"]))
        let asTwo = ids(try await call(rig, "chat.threads", ["agentId": "agent_two"]))
        XCTAssertEqual(asUI, ["thread-one"], "no agent id, as the UI sends, is agent 1")
        XCTAssertEqual(asOne, ["thread-one"])
        XCTAssertEqual(asTwo, ["thread-two"])
        let unknown = try await call(rig, "chat.threads", ["agentId": "agent_nine"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32001, "an unknown agent is notFound")
    }

    func testTheChatThreadsToolListsAsTheCallingAgentOrTheOneNamed() async throws {
        let rig = try ContractRig(seed: ["agentTwo"])
        func list(_ arguments: [String: Any], agent: String?) async throws -> (ids: [String], isError: Bool) {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                   "params": ["name": "chat_threads_list", "arguments": arguments]])
            let result = await MCPEndpoint.handle(body, automations: nil, tasks: nil, agent: agent, chat: rig.api.chat)
            let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
            let content = try XCTUnwrap(reply["result"] as? [String: Any])
            let text = ((content["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            let threads = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["threads"] as? [[String: Any]] ?? []
            return (threads.compactMap { $0["id"] as? String }, content["isError"] as? Bool ?? false)
        }
        let noCaller = try await list([:], agent: nil)
        let calling = try await list([:], agent: "agent_two")
        let explicit = try await list(["agentId": "agent_default"], agent: "agent_two")
        let unknown = try await list(["agentId": "agent_nine"], agent: nil)
        XCTAssertEqual(noCaller.ids, ["thread-one"], "no caller is agent 1")
        XCTAssertEqual(calling.ids, ["thread-two"], "the calling agent")
        XCTAssertEqual(explicit.ids, ["thread-one"], "an explicit id wins")
        XCTAssertTrue(unknown.isError)
    }

    // MARK: S4, sessions

    func testSessionsListAsEachAgent() async throws {
        let rig = try ContractRig(seed: ["agentTwo"])
        let asUI = ids(try await call(rig, "agents.list"))
        let asTwo = ids(try await call(rig, "agents.list", ["agentId": "agent_two"]))
        XCTAssertEqual(asUI, ["session-1"], "agent 1 only")
        XCTAssertEqual(asTwo, ["session-2"])
        let unknown = try await call(rig, "agents.list", ["agentId": "agent_nine"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    func testTheSessionToolsListAsTheCallingAgent() throws {
        let context = AssistantContext()
        let sessions = [AgentSession(id: "s1", source: .claude, status: .running), AgentSession(id: "s2", source: .codex, status: .running, agentId: "agent_two")]
        context.sessions = { sessions }
        context.resolveAgent = { id in
            let resolved = AgentOwner.id(id)
            guard ["agent_default", "agent_two"].contains(resolved) else { throw APIError.notFound("no agent with id \"\(resolved)\"") }
            return resolved
        }
        func listed(_ args: [String: Any], agent: String?) throws -> [String] {
            switch AssistantMCP.call("status_sessions", args, context: context, agent: agent) {
            case .success(let value): return ((value as? [String: Any])?["sessions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            case .failure(let error): throw error
            }
        }
        XCTAssertEqual(try listed([:], agent: nil), ["s1"])
        XCTAssertEqual(try listed([:], agent: "agent_two"), ["s2"])
        XCTAssertEqual(try listed(["agentId": "agent_default"], agent: "agent_two"), ["s1"])
        XCTAssertThrowsError(try listed(["agentId": "agent_nine"], agent: nil))
    }

    // MARK: S4 and S5, automations

    private func automationRig() throws -> (api: AutomationsAPI, service: AutomationService) {
        let database = Database.open(path: nil, migrations: AppMigrations.all).database
        try ContractRig.addAgent("agent_two", number: 2, cli: "claude", model: "opus", to: database)
        let paths = AutomationPaths(file: directory.appendingPathComponent("automations.json"), directory: directory.appendingPathComponent("automations"))
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        let engine = AutomationEngine(env: AutomationEngine.Environment(now: Date.init, calendar: Calendar(identifier: .gregorian)))
        let service = AutomationService(store: store, engine: engine)
        service.registry = AgentRegistry(database: database)
        return (AutomationsAPI(service: service), service)
    }

    private func definition(_ name: String) -> String {
        "{\"name\":\"\(name)\",\"trigger\":{\"type\":\"interval\",\"minutes\":30,\"clock\":\"wall\"},\"action\":{\"type\":\"bubble\",\"title\":\"hi\"}}"
    }

    func testAnAutomationIsCreatedForTheAgentNamedOrAgentOne() throws {
        let (api, _) = try automationRig()
        XCTAssertEqual(try api.create(CreateAutomationRequest(definition: definition("From the UI"))).agentId, "agent_default")
        XCTAssertEqual(try api.create(CreateAutomationRequest(definition: definition("For two"), agentId: "agent_two")).agentId, "agent_two")
        XCTAssertThrowsError(try api.create(CreateAutomationRequest(definition: definition("For nobody"), agentId: "agent_nine"))) { error in
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
        XCTAssertFalse(api.automations.contains { $0.name == "For nobody" })
    }

    func testAutomationsListAsEachAgentWithTheBuiltInsForBoth() async throws {
        let (api, _) = try automationRig()
        _ = try api.create(CreateAutomationRequest(definition: definition("Mine")))
        _ = try api.create(CreateAutomationRequest(definition: definition("Theirs"), agentId: "agent_two"))
        let nodeLevel = Set(AutomationDefaults.builtIns.map(\.id))
        let one = try api.list(agentId: nil)
        let two = try api.list(agentId: "agent_two")
        XCTAssertEqual(Set(one.map(\.id)), nodeLevel.union(["mine"]), "agent 1 sees its own and the node-level ones")
        XCTAssertEqual(Set(two.map(\.id)), nodeLevel.union(["theirs"]), "agent 2 does not see agent 1's automation")
        XCTAssertEqual(try api.list(agentId: "agent_default").map(\.id), one.map(\.id))
        XCTAssertThrowsError(try api.list(agentId: "agent_nine")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        for builtIn in AutomationDefaults.builtIns { XCTAssertNil(builtIn.ownerAgentID, "\(builtIn.id) has no owner") }
        XCTAssertNil(AutomationDefaults.taskScan(minutes: 30).ownerAgentID)
    }

    func testTheAutomationToolsListAndCreateAsTheCallingAgent() async throws {
        let (api, _) = try automationRig()
        func names(_ result: Result<Any, AutomationError>) throws -> [String] {
            ((try result.get()) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.filter { !["Morning brief", "End-of-day recap", "Task review", "Mail and calendar checks"].contains($0) }
        }
        let created = try await api.callJSON("create", ["name": "Theirs", "trigger": ["type": "interval", "minutes": 30, "clock": "wall"],
                                                       "action": ["type": "bubble", "title": "hi"]], by: "agent:mcp", agent: "agent_two").get()
        XCTAssertEqual((created as? [String: Any])?["agentId"] as? String, "agent_two", "the calling agent owns what it creates")
        _ = try await api.callJSON("create", ["name": "Mine", "trigger": ["type": "interval", "minutes": 30, "clock": "wall"],
                                              "action": ["type": "bubble", "title": "hi"]], by: "agent:mcp").get()
        let asOne = try names(await api.callJSON("list", [:], by: "agent:mcp"))
        let asTwo = try names(await api.callJSON("list", [:], by: "agent:mcp", agent: "agent_two"))
        let named = try names(await api.callJSON("list", ["agentId": "agent_default"], by: "agent:mcp", agent: "agent_two"))
        XCTAssertEqual(asOne, ["Mine"])
        XCTAssertEqual(asTwo, ["Theirs"])
        XCTAssertEqual(named, ["Mine"])
        switch await api.callJSON("list", ["agentId": "agent_nine"], by: "agent:mcp") {
        case .success: XCTFail("an unknown agent is an error")
        case .failure(let error): XCTAssertTrue(error.message.hasPrefix("no agent"), error.message)
        }
    }

    func testTheOwnerOfAnAutomationCallerIsTheCallingAgent() async throws {
        let (api, _) = try automationRig()
        _ = try api.create(CreateAutomationRequest(definition: definition("Theirs"), agentId: "agent_two"))
        XCTAssertEqual(api.owner(of: "theirs"), "agent_two")
        XCTAssertNil(api.owner(of: "morning-brief"), "a built-in has no owner")
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": "automations_list", "arguments": [String: Any]()]])
        let result = await MCPEndpoint.handle(body, automations: api, tasks: nil, caller: "automation:theirs")
        let text = String(decoding: result.body, as: UTF8.self)
        XCTAssertTrue(text.contains("Theirs"), "the automation's own session lists its owner's automations")
    }

    func testAnOwnerWrittenOnABuiltInIsIgnored() throws {
        var morning = AutomationDefaults.morningBrief()
        morning.agentId = "agent_two"
        XCTAssertNil(morning.ownerAgentID)
        XCTAssertTrue(morning.isVisible(to: "agent_default"))
        XCTAssertTrue(morning.isVisible(to: "agent_two"))
    }
}
