import XCTest
@testable import IronPet
@testable import IronPetCore

/// The scheduler runs an automation for the agent that owns it: that agent's CLI, model and permissions, and its chat.
@MainActor
final class AutomationOwnerTests: AutomationTestCase {
    private var threads: URL!
    private var savedThreads: URL!
    private var turns: [ACPTurn] = []
    private var registry: AgentRegistry!

    override func setUp() async throws {
        try await super.setUp()
        savedThreads = ThreadStore.directory
        threads = dir.appendingPathComponent("threads")
        ThreadStore.directory = threads
        turns = []
        let database = Database.open(path: nil, migrations: AppMigrations.all).database
        registry = AgentRegistry(database: database)
        // No API creates a second agent yet, so the test writes the row.
        try database.write { db in
            try db.execute("""
                INSERT INTO agents(id, number, name, agent_cli, model, permissions, created, updated)
                VALUES('agent_two', 2, 'Agent 2', 'claude', 'opus', '{"Bash(rm:*)":"deny","Read":"allow"}', 0, 0)
                """)
        }
    }

    override func tearDown() async throws {
        ThreadStore.directory = savedThreads
        try await super.tearDown()
    }

    private var scripted: AutomationSession.TurnRunner {
        { [unowned self] turn, emit in
            turns.append(turn)
            emit(.session("s\(turns.count)"))
            emit(.assistant("Checked."))
            emit(.finished(error: nil))
        }
    }

    private func job(_ id: String, owner: String?, report: String? = nil, session: String? = "new", model: String? = nil) -> Automation {
        Automation(id: id, name: id, trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: "Check the mail", model: model, session: session, report: report), createdBy: "user", agentId: owner)
    }

    // S2: the runner is invoked with the owner's CLI, model and permissions

    func testTheRuntimeIsTheOwnersNotAgentOnes() {
        let two = AutomationPrompt.runtime(for: job("two", owner: "agent_two"), registry: registry)
        XCTAssertEqual(two.cli, "claude")
        XCTAssertEqual(two.model, "opus")
        XCTAssertEqual(two.permissions, ["Bash(rm:*)": "deny", "Read": "allow"])

        let one = AutomationPrompt.runtime(for: job("one", owner: nil), registry: registry)
        XCTAssertEqual(one.cli, "cursor", "agent 1's own CLI")
        XCTAssertNil(one.model, "agent 1 keeps the CLI's default model, as automations always have")
        XCTAssertEqual(one.permissions, [:])
    }

    func testAnActionsOwnModelAndAgentStillWin() {
        let model = AutomationPrompt.runtime(for: job("two", owner: "agent_two", model: "haiku"), registry: registry)
        XCTAssertEqual(model.model, "haiku")
        var other = job("two", owner: "agent_two")
        other.action.agent = "cursor"
        let runtime = AutomationPrompt.runtime(for: other, registry: registry)
        XCTAssertEqual(runtime.cli, "cursor")
        XCTAssertNil(runtime.model, "the owner's model belongs to the owner's CLI, so it is not sent to another one")
    }

    func testASessionRunAsAgentTwoAsksForAgentTwosModelAndSavesAnOwnedThread() async {
        let a = job("two", owner: "agent_two")
        _ = await AutomationSession.run(a, prompt: "Check the mail", workspace: dir.appendingPathComponent("ws"), spawner: UnsupportedProcessSpawner(),
                                        turnRunner: scripted, registry: registry)
        XCTAssertEqual(turns.last?.model, "opus")
        let thread = ThreadStore.latest(automation: "two")
        XCTAssertEqual(thread?.agent, "claude")
        XCTAssertEqual(thread?.agentId, "agent_two")
        XCTAssertEqual(ThreadStore.recent(agent: "agent_two").map(\.id), [thread?.id])
        XCTAssertEqual(ThreadStore.recent(agent: "agent_default").count, 0, "agent 1 does not see it")

        let one = job("one", owner: nil)
        _ = await AutomationSession.run(one, prompt: "Check the mail", workspace: dir.appendingPathComponent("ws"), spawner: UnsupportedProcessSpawner(),
                                        turnRunner: scripted, registry: registry)
        XCTAssertNil(turns.last?.model)
        XCTAssertEqual(ThreadStore.latest(automation: "one")?.agentId, "agent_default", "an unowned automation is agent 1's")
    }

    func testTheOwnersPermissionsAnswerAToolCall() {
        func call(_ kind: String, _ title: String, tool: String? = nil, command: String = "") -> ACPToolCall {
            ACPToolCall(id: "c", title: title, kind: kind, rawInput: ["command": command], toolName: tool)
        }
        let permissions = ["Bash(rm:*)": "deny", "Read": "allow", "Bash(make:*)": "allow"]
        func decision(_ route: AutomationSession.Route) -> Bool? {
            if case .answer(let answer) = route { return answer.allow }
            return nil
        }
        XCTAssertEqual(decision(AutomationSession.route(for: call("execute", "rm -rf x", tool: "Bash", command: "rm -rf x"), allowed: ["Bash"], disallowed: nil,
                                                         permissions: permissions)), false, "the owner's deny beats the automation's allowedTools")
        XCTAssertEqual(decision(AutomationSession.route(for: call("execute", "make", tool: "Bash", command: "make test"), allowed: nil, disallowed: nil,
                                                        permissions: permissions)), true, "the owner's allow")
        XCTAssertNil(decision(AutomationSession.route(for: call("execute", "ls", tool: "Bash", command: "ls"), allowed: nil, disallowed: nil,
                                                      permissions: permissions)), "no rule matches, so it still asks")
        XCTAssertEqual(decision(AutomationSession.route(for: call("execute", "make", tool: "Bash", command: "make"), allowed: nil, disallowed: ["Bash"],
                                                        permissions: permissions)), false, "the automation's disallowedTools beats the owner's allow")
        XCTAssertFalse(AutomationPrompt.decision(for: call("execute", "rm -rf x", tool: "Bash", command: "rm -rf x"), permissions: permissions).allow)
    }

    // S2: a result posted to the chat goes to the owner's main chat

    func testAResultReportedToTheChatGoesToTheOwnersChat() async {
        let rig = makeRig([job("one", owner: nil, report: "chat"), job("two", owner: "agent_two", report: "chat")])
        var ranFor: [String] = []
        rig.service.runSession = { a, _, _ in ranFor.append(a.id); return .success("answer from \(a.id)") }
        var chatOne: [String] = [], chatTwo: [String] = []
        rig.service.postNotice = { _, _, text, _ in chatOne.append(text) }
        rig.service.agentChats["agent_two"] = .init(postNotice: { _, _, text, _ in chatTwo.append(text) })

        _ = await rig.service.call("run_now", ["id": "two"], by: "user")
        await until("agent two's notice") { !chatTwo.isEmpty }
        XCTAssertEqual(chatTwo, ["answer from two"])
        XCTAssertEqual(chatOne, [], "agent 1's chat got nothing")

        _ = await rig.service.call("run_now", ["id": "one"], by: "user")
        await until("agent one's notice") { !chatOne.isEmpty }
        XCTAssertEqual(chatOne, ["answer from one"])
        XCTAssertEqual(chatTwo, ["answer from two"], "agent 2's chat got nothing more")
        XCTAssertEqual(ranFor, ["two", "one"])
    }

    func testAPromptSentToTheChatGoesToTheOwnersChat() async {
        let rig = makeRig([job("one", owner: nil, session: nil), job("two", owner: "agent_two", session: nil)])
        var sentOne: [String] = [], sentTwo: [String] = []
        rig.service.sendToChat = { id, _ in sentOne.append(id); return true }
        rig.service.agentChats["agent_two"] = .init(sendToChat: { id, _ in sentTwo.append(id); return true })
        _ = await rig.service.call("run_now", ["id": "two"], by: "user")
        XCTAssertEqual(sentTwo, ["two"])
        XCTAssertEqual(sentOne, [])
        _ = await rig.service.call("run_now", ["id": "one"], by: "user")
        XCTAssertEqual(sentOne, ["one"])
        XCTAssertEqual(sentTwo, ["two"])
    }

    func testAnOwnerWithNoChatDoesNotFallBackToAgentOnesChat() async {
        let rig = makeRig([job("two", owner: "agent_two", report: "chat")])
        var chatOne: [String] = []
        rig.service.postNotice = { _, _, text, _ in chatOne.append(text) }
        rig.service.runSession = { _, _, _ in .success("answer") }
        _ = await rig.service.call("run_now", ["id": "two"], by: "user")
        await until("the run") { rig.service.history("two", limit: 1).first?["output"] != nil }
        XCTAssertEqual(chatOne, [], "agent 2's result never lands in agent 1's chat")
    }

    // S5: node-level automations run as before

    func testANodeLevelAutomationStillReportsToAgentOnesChat() async {
        var review = AutomationDefaults.taskReview(enabled: true)
        review.action = .init(type: "prompt", prompt: "Review", session: "new", report: "chat")
        let rig = makeRig([review])
        var chatOne: [String] = []
        rig.service.postNotice = { _, _, text, _ in chatOne.append(text) }
        rig.service.runSession = { _, _, _ in .success("reviewed") }
        _ = await rig.service.call("run_now", ["id": review.id], by: "user")
        await until("the notice") { !chatOne.isEmpty }
        XCTAssertEqual(chatOne, ["reviewed"])
        XCTAssertEqual(AutomationPrompt.runtime(for: review, registry: registry).cli, "cursor", "it runs on agent 1's CLI, as before")
    }
}
