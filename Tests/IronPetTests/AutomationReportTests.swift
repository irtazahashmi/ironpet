import XCTest
@testable import IronPet

/// `session` main/new/own/fork and `report` bubble/chat (S1 to S4, S8, S9).
@MainActor
final class AutomationReportTests: AutomationTestCase {
    private func action(_ json: String) throws -> Automation.Action {
        try JSONDecoder().decode(Automation.Action.self, from: Data(json.utf8))
    }

    private func job(session: String? = nil, report: String? = nil, quiet: Automation.QuietReplies? = nil, prompt: String = "/review") -> Automation {
        Automation(id: "review", name: "Task review", trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: prompt, agent: "cursor", quiet: quiet, session: session, report: report))
    }

    // S1
    func testOldShapesKeepTheirTarget() throws {
        let json = """
        {"automations":[
         {"id":"a","name":"a","trigger":{"type":"interval","minutes":5},"action":{"type":"prompt","prompt":"x"}},
         {"id":"b","name":"b","trigger":{"type":"interval","minutes":5},"action":{"type":"prompt","prompt":"x","session":"chat"}},
         {"id":"c","name":"c","trigger":{"type":"interval","minutes":5},"action":{"type":"prompt","prompt":"x","session":"new","quiet":"OK"}},
         {"id":"d","name":"d","trigger":{"type":"interval","minutes":5},"action":{"type":"prompt","prompt":"x","session":"own"}}]}
        """
        let parsed = AutomationValidator.parse(Data(json.utf8))
        XCTAssertEqual(parsed.errors, [])
        let actions = parsed.automations.map(\.action)
        XCTAssertEqual(actions.map(\.effectiveSession), ["main", "main", "new", "own"])
        XCTAssertEqual(actions.map { $0.effectiveReport ?? "-" }, ["-", "-", "bubble", "bubble"])
        XCTAssertEqual(actions.map(\.runsInOwnSession), [false, false, true, true])
        XCTAssertEqual(actions[2].quietReplies, ["OK"])
        XCTAssertEqual(actions[2].session, "new")
        // An approval given before `report` existed stays valid.
        XCTAssertEqual(parsed.automations[2].riskText, "prompt:x||" + "|session:new|allow:|deny:")
    }

    func testItemPromptsStayReadOnlyBubbles() {
        let rig = makeRig([job(session: "new", report: "chat", prompt: "{{item.title}}")])
        XCTAssertFalse(rig.service.runsInSession(rig.store.automations[0]))
    }

    // S2
    func testDefaultsAndValidation() throws {
        XCTAssertEqual(try action(#"{"type":"prompt","prompt":"x","report":"chat"}"#).effectiveSession, "new")
        XCTAssertEqual(try action(#"{"type":"prompt","prompt":"x","session":"fork"}"#).effectiveReport, "chat")
        XCTAssertEqual(try action(#"{"type":"prompt","prompt":"x","session":"fork","report":"bubble"}"#).effectiveReport, "bubble")
        XCTAssertNil(try action(#"{"type":"prompt","prompt":"x","session":"main","report":"chat"}"#).effectiveReport)
        XCTAssertEqual(try action(#"{"type":"prompt","prompt":"x","session":"new","report":"chat"}"#).quietReplies, ["NOTHING", "NOTHING_NEW"])
        XCTAssertEqual(try action(#"{"type":"prompt","prompt":"x","session":"new","quiet":["A","B"]}"#).quietReplies, ["A", "B"])
        func errors(_ action: String) -> [String] {
            AutomationValidator.parse(Data(#"{"automations":[{"id":"a","name":"a","trigger":{"type":"interval","minutes":5},"action":\#(action)}]}"#.utf8)).errors
        }
        XCTAssertEqual(errors(#"{"type":"prompt","prompt":"x","session":"fork","report":"chat"}"#), [])
        XCTAssertTrue(errors(#"{"type":"prompt","prompt":"x","session":"x"}"#).joined().contains("action.session must be one of"))
        XCTAssertTrue(errors(#"{"type":"prompt","prompt":"x","report":"y"}"#).joined().contains("action.report must be one of bubble, chat"))
        // fork and report change what the prompt may do, so they change the approval text.
        XCTAssertNotEqual(job(session: "new").riskText, job(session: "fork").riskText)
        XCTAssertNotEqual(job(session: "new").riskText, job(session: "new", report: "chat").riskText)
        XCTAssertEqual(job().riskText, job(session: "main").riskText)
    }

    private func reporting(_ answer: String, quiet: Automation.QuietReplies? = nil) -> (Rig, notices: () -> [String], turns: () -> Int) {
        let rig = makeRig([job(session: "new", report: "chat", quiet: quiet)])
        var notices: [String] = []
        var turns = 0
        rig.service.runSession = { _, _, _ in .success(answer) }
        rig.service.postNotice = { kind, title, text, triggers in notices.append("\(kind)|\(title)|\(text)"); if triggers { turns += 1 } }
        return (rig, { notices }, { turns })
    }

    // S3
    func testSentinelsPostNothingAndOtherTextPostsATriggeringNotice() async {
        for (answer, quiet) in [("", nil), ("NOTHING", nil), (" NOTHING_NEW\n", nil), ("ALL CLEAR", .init(["ALL CLEAR", "x"])),
                                ("none", .init(stringLiteral: "none"))] as [(String, Automation.QuietReplies?)] {
            let (rig, notices, turns) = reporting(answer, quiet: quiet)
            run(rig, minutes: 60)
            await until("history for '\(answer)'") { rig.service.history("review", limit: 20).first?["output"] == "no changes" }
            XCTAssertEqual(notices(), [], answer)
            XCTAssertEqual(turns(), 0)
        }
        let (rig, notices, turns) = reporting("2 PRs are stale")
        run(rig, minutes: 60)
        await until("notice") { !notices().isEmpty }
        XCTAssertEqual(notices(), ["automation:review|Automation: Task review|2 PRs are stale"])
        XCTAssertEqual(turns(), 1)
        XCTAssertTrue(rig.notices.all.isEmpty, "no bubble")
    }

    func testFailureNoticeDoesNotTriggerATurn() async {
        let rig = makeRig([job(session: "new", report: "chat")])
        var posted: [(String, Bool)] = []
        rig.service.runSession = { _, _, _ in .failure(.init(message: "boom")) }
        rig.service.postNotice = { _, title, text, triggers in posted.append((title + ": " + text, triggers)) }
        run(rig, minutes: 60)
        await until("failure notice") { !posted.isEmpty }
        XCTAssertEqual(posted.map(\.0), ["Automation: Task review failed: boom"])
        XCTAssertEqual(posted.map(\.1), [false])
        XCTAssertEqual(rig.service.history("review", limit: 20).first?["outcome"], "failed")
    }

    // S4
    func testOverlappingTickIsSkipped() async {
        let rig = makeRig([job(session: "new", report: "chat")])
        var release: (() -> Void)?
        rig.service.runSession = { _, _, _ in await withCheckedContinuation { c in release = { c.resume() } }; return .success("NOTHING") }
        rig.service.postNotice = { _, _, _, _ in }
        run(rig, minutes: 60)
        await until("first run started") { release != nil }
        run(rig, minutes: 60)
        XCTAssertTrue(rig.service.history("review", limit: 20).contains { $0["output"] == "the previous run is still going" })
        release?()
    }

    // S8, S9
    func testForkPassesTheMainSessionAndFallsBackWithAWarning() async {
        let rig = makeRig([job(session: "fork")])
        var forks: [String?] = []
        rig.service.runSession = { _, _, fork in forks.append(fork); return .success("NOTHING") }
        rig.service.postNotice = { _, _, _, _ in }
        rig.service.forkSource = { _ in "main-session" }
        run(rig, minutes: 60)
        await until("forked run") { forks.count == 1 }
        XCTAssertEqual(forks, ["main-session"])

        rig.service.forkSource = { _ in nil }
        run(rig, minutes: 60)
        await until("fallback run") { forks.count == 2 }
        XCTAssertEqual(forks.last!, nil)
        XCTAssertTrue(rig.service.history("review", limit: 20).contains { $0["outcome"] == "warning" && ($0["output"] ?? "").contains("fork not supported by") })
    }

    func testForkTurnCarriesTheSourceSession() async {
        let a = job(session: "fork")
        var seen: [ACPTurn] = []
        let runner: AutomationSession.TurnRunner = { turn, emit in
            seen.append(turn)
            emit(.session("forked-1"))
            emit(.assistant("done"))
            emit(.finished(error: nil))
        }
        let saved = ThreadStore.directory
        ThreadStore.directory = dir.appendingPathComponent("threads")
        defer { ThreadStore.directory = saved }
        _ = await AutomationSession.run(a, prompt: "/review", workspace: dir.appendingPathComponent("ws"), spawner: UnsupportedProcessSpawner(), turnRunner: runner, fork: "main-session")
        XCTAssertEqual(seen.first?.fork, "main-session")
        _ = await AutomationSession.run(job(session: "new"), prompt: "/review", workspace: dir.appendingPathComponent("ws"), spawner: UnsupportedProcessSpawner(), turnRunner: runner)
        XCTAssertNil(seen.last?.fork)
    }
}
