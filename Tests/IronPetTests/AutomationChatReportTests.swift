import XCTest
@testable import IronPet
@testable import IronPetCore

/// Shell and script automations that report to the main chat, and automations that delete themselves (`until`, `done`).
@MainActor
final class AutomationChatReportTests: AutomationTestCase {
    struct Posted: Equatable {
        var kind: String
        var title: String
        var text: String
        var triggersTurn: Bool
    }

    private func shell(_ command: String = "gh pr view 1", report: String? = "chat", quiet: Automation.QuietReplies? = nil,
                       until: String? = nil) -> Automation {
        Automation(id: "watch", name: "Watch PR", trigger: .init(type: "interval", minutes: 3, clock: "wall"),
                   action: .init(type: "shell", command: command, quiet: quiet, report: report), createdBy: "user", until: until)
    }

    private func script() -> Automation {
        Automation(id: "ci", name: "CI", trigger: .init(type: "script", minutes: 1, script: "function poll() {}"), action: .init(type: "none"),
                   createdBy: "user")
    }

    private func shellRig(_ a: Automation, result: @escaping () -> CommandResult) -> (Rig, posted: () -> [Posted]) {
        let rig = makeRig([a])
        var posted: [Posted] = []
        rig.service.postNotice = { posted.append(Posted(kind: $0, title: $1, text: $2, triggersTurn: $3)) }
        rig.service.runShell = { _, _ in result() }
        return (rig, { posted })
    }

    // S1
    func testShellReportChatPostsNameCommandExitCodeAndOutputAndStartsATurn() async {
        let (rig, posted) = shellRig(shell("gh pr view 1"), result: { CommandResult(code: 0, stdout: "MERGED\n", stderr: "warning: slow\n") })
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("notice") { !posted().isEmpty }
        let notice = posted()[0]
        XCTAssertEqual(notice.kind, "automation:watch")
        XCTAssertEqual(notice.title, "Automation: Watch PR")
        XCTAssertTrue(notice.text.contains("\"Watch PR\""), notice.text)
        XCTAssertTrue(notice.text.contains("Command: gh pr view 1"), notice.text)
        XCTAssertTrue(notice.text.contains("exit code 0"), notice.text)
        XCTAssertTrue(notice.text.contains("MERGED"), notice.text)
        XCTAssertTrue(notice.text.contains("warning: slow"), notice.text)
        XCTAssertTrue(notice.triggersTurn)
        XCTAssertTrue(rig.notices.all.isEmpty, "no bubble")
        await until("history") { rig.service.history("watch", limit: 5).first?["output"]?.hasPrefix("posted to chat") == true }
    }

    func testShellOutputTailIsFourKilobytes() async {
        let output = String(repeating: "a", count: 10_000) + "THE END"
        let (rig, posted) = shellRig(shell(), result: { CommandResult(code: 0, stdout: output) })
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("notice") { !posted().isEmpty }
        let text = posted()[0].text
        XCTAssertTrue(text.contains("THE END"))
        XCTAssertTrue(text.contains("(last 4 KB)"))
        XCTAssertLessThan(text.utf8.count, 4096 + 400)
    }

    func testShellWithoutReportKeepsTheBubble() async {
        let (rig, posted) = shellRig(shell(report: nil), result: { CommandResult(code: 0, stdout: "ok") })
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("bubble") { !rig.notices.all.isEmpty }
        XCTAssertEqual(posted(), [])
    }

    // S5
    func testQuietOutputPostsNothingAndAFailurePostsWithoutATurn() async {
        var result = CommandResult(code: 0, stdout: "NOTHING\n")
        let (rig, posted) = shellRig(shell(quiet: "NOTHING"), result: { result })
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("quiet history") { rig.service.history("watch", limit: 5).first?["output"] == "no changes" }
        XCTAssertEqual(posted(), [])
        result = CommandResult(code: 2, stdout: "", stderr: "boom\n")
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("failure notice") { !posted().isEmpty }
        XCTAssertEqual(posted()[0].title, "Automation: Watch PR failed")
        XCTAssertFalse(posted()[0].triggersTurn)
        XCTAssertTrue(posted()[0].text.contains("exit code 2"))
        XCTAssertTrue(posted()[0].text.contains("boom"))
    }

    // S3
    func testUntilSuccessKeepsTheAutomationOnAFailureAndDeletesItAfterTheReportOnExitZero() async throws {
        var result = CommandResult(code: 1, stdout: "OPEN")
        let (rig, posted) = shellRig(shell(until: "success"), result: { result })
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("failure notice") { posted().count == 1 }
        XCTAssertEqual(rig.store.automations.map(\.id), ["watch"])
        result = CommandResult(code: 0, stdout: "MERGED")
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("deleted") { rig.store.automations.isEmpty }
        XCTAssertEqual(posted().count, 2)
        XCTAssertTrue(posted()[1].triggersTurn)
        XCTAssertTrue(posted()[1].text.contains("MERGED"))
        XCTAssertEqual(try AutomationValidator.parse(Data(contentsOf: paths.file)).automations, [])
        let outcomes = rig.service.history("watch", limit: 10).map { $0["outcome"] }
        XCTAssertEqual(outcomes.first, "deleted", "newest first")
        XCTAssertTrue(rig.service.history("watch", limit: 10).first?["output"]?.contains("succeeded") == true)
        XCTAssertEqual(rig.engine.state.logs(automation: "watch").first?.outcome, "deleted", "the execution log has it too")
        let viaAPI = await rig.service.call("history", ["id": "watch"], by: "user")
        guard case .success(let value) = viaAPI, let rows = value as? [[String: String]] else { return XCTFail("history of a deleted automation: \(viaAPI)") }
        XCTAssertEqual(rows.first?["outcome"], "deleted")
    }

    func testPruneAtLaunchKeepsTheHistoryOfAnAutomationThatDeletedItself() {
        let state = AutomationState()
        let now = Date()
        state.record("gone", .init(date: now, outcome: "deleted", output: "deleted itself: succeeded"))
        state.addLog("gone", date: now, duration: 0, outcome: "deleted", summary: "deleted itself", detail: "")
        state.record("orphan", .init(date: now, outcome: "ok", output: "x"))
        state.prune(now: now, keeping: ["watch"])
        XCTAssertEqual(state.history("gone").first?.outcome, "deleted")
        XCTAssertEqual(state.logs(automation: "gone").first?.outcome, "deleted")
        XCTAssertTrue(state.history("orphan").isEmpty)
    }

    func testUntilOnceDeletesAfterAFailureToo() async {
        let (rig, posted) = shellRig(shell(until: "once"), result: { CommandResult(code: 3, stdout: "no") })
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("deleted") { rig.store.automations.isEmpty }
        XCTAssertEqual(posted().count, 1)
        XCTAssertFalse(posted()[0].triggersTurn)
    }

    func testUntilSuccessWithBubbleReportDeletesAfterTheBubble() async {
        let (rig, _) = shellRig(shell(report: nil, until: "success"), result: { CommandResult(code: 0, stdout: "done") })
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("deleted") { rig.store.automations.isEmpty }
        XCTAssertEqual(rig.notices.all.count, 1, "the bubble was shown first")
    }

    func testAnEditWhileTheCommandRunsKeepsTheAutomation() async {
        let a = shell(until: "success")
        let rig = makeRig([a])
        rig.service.postNotice = { _, _, _, _ in }
        rig.service.runShell = { _, _ in
            try? rig.store.update("watch") { $0.action.command = "something else" }
            return CommandResult(code: 0, stdout: "x")
        }
        _ = await rig.service.call("run_now", ["id": "watch"], by: "user")
        await until("not deleted note") { rig.service.history("watch", limit: 5).contains { $0["output"]?.contains("not deleted") == true } }
        XCTAssertEqual(rig.store.automations.map(\.id), ["watch"])
    }

    // S2
    func testScriptChatActionPostsANoticeThatStartsATurn() async {
        let rig = makeRig([script()])
        var posted: [Posted] = []
        rig.service.postNotice = { posted.append(Posted(kind: $0, title: $1, text: $2, triggersTurn: $3)) }
        rig.engine.runScript = { _, _ in
            AutomationScript.Output(state: "{}", actions: [["type": .init(value: "chat"), "text": .init(value: "hello")]], logs: [])
        }
        await rig.engine.pollNow("ci")
        XCTAssertEqual(posted, [Posted(kind: "automation:ci", title: "Automation: CI", text: "hello", triggersTurn: true)])
        XCTAssertEqual(rig.store.automations.map(\.id), ["ci"], "no done, so it stays")
    }

    func testScriptChatActionTitleAndCap() async {
        let rig = makeRig([script()])
        var posted: [Posted] = []
        rig.service.postNotice = { posted.append(Posted(kind: $0, title: $1, text: $2, triggersTurn: $3)) }
        let big = String(repeating: "x", count: 70 * 1024)
        rig.service.perform([["type": "chat", "text": big, "title": "Big\nnews"], ["type": "chat"]], for: script(), firstRun: false)
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].title, "Automation: CI: Big news")
        XCTAssertLessThanOrEqual(posted[0].text.utf8.count, 64 * 1024 + 60)
        XCTAssertTrue(posted[0].text.hasSuffix("(text cut off at 64 KiB)"))
        XCTAssertEqual(rig.service.history("ci", limit: 5).first?["output"], "action 2: a chat action needs text")
    }

    func testChatActionCountsTowardTheTwentyActionLimit() async throws {
        let output = try await AutomationScript.run(script: "function poll() { const a = []; for (let i = 0; i < 25; i++) a.push({type: 'chat', text: 't' + i}); return {actions: a}; }",
                                                    state: nil, host: .init(sh: { _, _ in CommandResult() }))
        XCTAssertEqual(output.actions.count, 20)
        XCTAssertFalse(output.done)
    }

    // S4
    func testScriptDoneRunsItsActionsThenDeletesTheAutomation() async throws {
        let rig = makeRig([script()])
        var posted: [Posted] = []
        rig.service.postNotice = { posted.append(Posted(kind: $0, title: $1, text: $2, triggersTurn: $3)) }
        rig.engine.runScript = { _, _ in
            AutomationScript.Output(state: "{}", actions: [["type": .init(value: "chat"), "text": .init(value: "PR merged")]], logs: [], done: true)
        }
        await rig.engine.pollNow("ci")
        XCTAssertEqual(posted.map(\.text), ["PR merged"])
        XCTAssertEqual(rig.store.automations, [])
        XCTAssertEqual(try AutomationValidator.parse(Data(contentsOf: paths.file)).automations, [])
        let history = rig.service.history("ci", limit: 10)
        XCTAssertTrue(history.contains { $0["outcome"] == "deleted" }, "\(history)")
        let logs = rig.engine.state.logs(automation: "ci").map(\.outcome)
        XCTAssertEqual(logs.first, "deleted")
        XCTAssertTrue(logs.contains("ok"), "the run itself stays in the log: \(logs)")
    }

    func testScriptReturnsDoneFromJavaScript() async throws {
        let done = try await AutomationScript.run(script: "function poll(s) { return {state: s, actions: [], done: true}; }", state: nil,
                                                  host: .init(sh: { _, _ in CommandResult() }))
        XCTAssertTrue(done.done)
        let notDone = try await AutomationScript.run(script: "function poll(s) { return {done: 'yes'}; }", state: nil,
                                                     host: .init(sh: { _, _ in CommandResult() }))
        XCTAssertFalse(notDone.done, "only the boolean true counts")
    }

    // S6
    func testFieldsSurviveSavingAndReloading() throws {
        let a = shell(quiet: .init(["NOTHING", "NONE"]), until: "success")
        let rig = makeRig([a])
        let reloaded = AutomationStore(paths: paths, defaults: { [] }, watch: false)
        XCTAssertEqual(reloaded.automations, [a])
        XCTAssertEqual(reloaded.automations.first?.action.report, "chat")
        XCTAssertEqual(reloaded.automations.first?.until, "success")
        let engine = AutomationEngine(env: clock.environment)
        engine.set(reloaded.automations)
        XCTAssertEqual(engine.automations, [a])
        XCTAssertNotNil(engine.nextRun(a), "keeps running on schedule")
        _ = rig
        let decoded = try JSONDecoder().decode(Automation.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
    }

    func testOldFilesWithoutTheNewFieldsDecodeUnchanged() throws {
        let json = #"{"automations":[{"id":"a","name":"A","trigger":{"type":"interval","minutes":5},"action":{"type":"shell","command":"ls"}}]}"#
        let (list, errors) = AutomationValidator.parse(Data(json.utf8))
        XCTAssertEqual(errors, [])
        XCTAssertNil(list[0].until)
        XCTAssertNil(list[0].action.report)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(list[0]), as: UTF8.self).contains("until"))
        XCTAssertEqual(list[0].riskText, "shell:ls", "an approval given before report existed stays valid")
    }

    // S7
    func testValidationNamesTheProblem() {
        func errors(_ automation: String) -> [String] {
            AutomationValidator.parse(Data(#"{"automations":[\#(automation)]}"#.utf8)).errors
        }
        let trigger = #""trigger":{"type":"interval","minutes":5}"#
        XCTAssertEqual(errors(#"{"id":"a","name":"A",\#(trigger),"action":{"type":"shell","command":"ls","report":"chat"},"until":"success"}"#), [])
        XCTAssertTrue(errors(#"{"id":"a","name":"A",\#(trigger),"action":{"type":"bubble","title":"x","report":"chat"}}"#).joined()
            .contains("action.report only applies to prompt and shell actions, not bubble"))
        XCTAssertTrue(errors(#"{"id":"a","name":"A",\#(trigger),"action":{"type":"digest","digest":"brief","report":"chat"}}"#).joined()
            .contains("action.report only applies to prompt and shell actions, not digest"))
        XCTAssertTrue(errors(#"{"id":"a","name":"A",\#(trigger),"action":{"type":"shell","command":"ls","report":"email"}}"#).joined()
            .contains("action.report must be one of bubble, chat"))
        XCTAssertTrue(errors(#"{"id":"a","name":"A",\#(trigger),"action":{"type":"shell","command":"ls"},"until":"never"}"#).joined()
            .contains("until must be one of success, once"))
        XCTAssertTrue(errors(#"{"id":"a","name":"A",\#(trigger),"action":{"type":"shell","command":"ls","quiet":"x"}}"#).joined()
            .contains("needs \"report\": \"chat\""))
        XCTAssertTrue(errors(#"{"id":"a","name":"A","trigger":{"type":"script","minutes":1,"script":"function poll() {}"},"until":"once"}"#).joined()
            .contains("done: true"))
    }

    func testCreateAndUpdateThroughTheServiceRejectBadCombinations() async {
        let rig = makeRig([])
        let bad = await rig.service.call("create", ["name": "X", "trigger": ["type": "interval", "minutes": 5],
                                                    "action": ["type": "bubble", "title": "t", "report": "chat"]], by: "agent:mcp")
        guard case .failure(let error) = bad else { return XCTFail("should fail") }
        XCTAssertTrue(error.message.contains("action.report only applies"), error.message)
        let ok = await rig.service.call("create", ["name": "Y", "trigger": ["type": "interval", "minutes": 5, "clock": "wall"],
                                                   "action": ["type": "shell", "command": "true", "report": "chat"], "until": "success"], by: "user")
        guard case .success(let created) = ok, let dict = created as? [String: Any] else { return XCTFail("\(ok)") }
        XCTAssertEqual(dict["until"] as? String, "success")
        XCTAssertEqual((dict["action"] as? [String: Any])?["report"] as? String, "chat")
        let cleared = await rig.service.call("update", ["id": "y", "changes": ["until": NSNull()]], by: "user")
        guard case .success(let after) = cleared else { return XCTFail("\(cleared)") }
        XCTAssertNil((after as? [String: Any])?["until"])
    }

    func testAnAgentWrittenReportChatShellNeedsApprovalAndReportIsPartOfIt() {
        XCTAssertNotEqual(shell(report: nil).riskText, shell(report: "chat").riskText)
        let rig = makeRig([])
        XCTAssertTrue(rig.service.approvalDetail(shell(report: "chat")).contains("posts its output to the main chat"))
    }
}

/// The agent-facing tools and the CLI accept the new fields.
@MainActor
final class AutomationChatReportServerTests: AutomationTestCase {
    private var server: EventServer!
    private var rig: Rig!

    override func setUp() async throws {
        try await super.setUp()
        rig = makeRig([])
        let service = rig.service
        server = EventServer(token: "test-token") { _ in }
        server.onAgentAPI = { request, respond in MCPEndpoint.route(request, automations: { AutomationsAPI(service: service) }, tasks: { nil }, respond: respond) }
        try server.start(preferredPort: 47440)
        let port = String(server.port)
        AutomationCLI.endpoint = { (port, "test-token") }
    }

    override func tearDown() async throws {
        AutomationCLI.endpoint = {
            guard let port = try? String(contentsOf: Paths.portFile, encoding: .utf8),
                  let token = try? String(contentsOf: Paths.tokenFile, encoding: .utf8) else { return nil }
            return (port, token)
        }
        try await super.tearDown()
    }

    private func cli(_ args: [String]) async -> (code: Int32, out: String, err: String) {
        await Task.detached { AutomationCLI.execute(args) }.value
    }

    func testToolSchemasListUntilAndTheGuideExplainsReportAndChat() throws {
        let create = try XCTUnwrap(AutomationMCP.tools.first { $0["name"] as? String == "automations_create" })
        let schema = try XCTUnwrap(create["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let until = try XCTUnwrap(properties["until"] as? [String: Any])
        XCTAssertEqual(until["enum"] as? [String], ["success", "once"])
        let description = try XCTUnwrap(create["description"] as? String)
        XCTAssertTrue(description.contains("{\"type\":\"chat\",\"text\""))
        XCTAssertTrue(description.contains("done: true"))
        XCTAssertTrue(description.contains("\"report\"? (\"bubble\" or \"chat\")"))
        XCTAssertTrue(AutomationSchema.json.contains("\"until\""))
    }

    func testCLIAddUpdateAndGetShowTheFields() async throws {
        let add = await cli(["add", "--name", "Watch", "--command", "true", "--every", "3", "--report", "chat", "--until", "success"])
        XCTAssertEqual(add.code, 0, add.err)
        let stored = try XCTUnwrap(rig.store.automations.first)
        XCTAssertEqual(stored.action.type, "shell")
        XCTAssertEqual(stored.action.report, "chat")
        XCTAssertEqual(stored.until, "success")
        XCTAssertEqual(stored.trigger.clock, "wall")
        let get = await cli(["get", "watch"])
        XCTAssertTrue(get.out.contains("\"until\" : \"success\""), get.out)
        XCTAssertTrue(get.out.contains("\"report\" : \"chat\""), get.out)
        let update = await cli(["update", "watch", "--report", "bubble", "--until", "once"])
        XCTAssertEqual(update.code, 0, update.err)
        XCTAssertEqual(rig.store.automations.first?.action.report, "bubble")
        XCTAssertEqual(rig.store.automations.first?.until, "once")
        let clear = await cli(["update", "watch", "--until", "none"])
        XCTAssertEqual(clear.code, 0, clear.err)
        XCTAssertNil(rig.store.automations.first?.until)
    }

    func testCLIRejectsInvalidCombinationsWithClearErrors() async {
        let bubbleReport = await cli(["add", "--name", "B", "--every", "5", "--report", "chat"])
        XCTAssertEqual(bubbleReport.code, 1)
        XCTAssertTrue(bubbleReport.err.contains("--report needs --command"), bubbleReport.err)
        let badUntil = await cli(["add", "--name", "C", "--command", "true", "--every", "5", "--until", "never"])
        XCTAssertEqual(badUntil.code, 1)
        XCTAssertTrue(badUntil.err.contains("until must be one of success, once"), badUntil.err)
        let bubbleJSON = await cli(["add", "--json", #"{"name":"D","trigger":{"type":"interval","minutes":5},"action":{"type":"bubble","title":"t","report":"chat"}}"#])
        XCTAssertEqual(bubbleJSON.code, 1)
        XCTAssertTrue(bubbleJSON.err.contains("action.report only applies to prompt and shell actions"), bubbleJSON.err)
        XCTAssertEqual(rig.store.automations, [])
    }
}
