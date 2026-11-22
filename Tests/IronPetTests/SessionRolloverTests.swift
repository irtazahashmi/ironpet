import XCTest
@testable import IronPet
@testable import IronPetCore

/// A chat whose agent transcript passes the limit moves to a fresh agent session at its next idle moment.
@MainActor
final class SessionRolloverTests: AutomationTestCase {
    private var session: ChatSession!
    private var h: ChatHarness!
    private var deliver: [(AgentEvent) -> Void] = []
    private var turns: [ACPTurn] = []
    private var savedThreads: URL!
    private var savedRoot: URL!
    private var workspace: URL!

    override func setUp() async throws {
        try await super.setUp()
        TestMemory.isolate()
        savedThreads = ThreadStore.directory
        savedRoot = AgentTranscript.root
        ThreadStore.directory = dir.appendingPathComponent("threads")
        AgentTranscript.root = dir.appendingPathComponent("projects")
        workspace = dir.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        deliver = []
        turns = []
        h = ChatHarness()
        session = h.session
        session.setAgent(AgentCatalog.agent(id: "claude")!)
        session.workspace = workspace
        session.rolloverLimit = { 100 }
        session.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
    }

    override func tearDown() async throws {
        ThreadStore.directory = savedThreads
        AgentTranscript.root = savedRoot
        try await super.tearDown()
    }

    private func settle() async { for _ in 0..<8 { await Task.yield() } }

    private func transcript(_ id: String, bytes: Int) throws -> URL {
        let folder = AgentTranscript.root.appendingPathComponent(AgentTranscript.slug(workspace.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id).jsonl")
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    /// Sends a message and leaves the turn running on session `s1`.
    private func startTurn(_ text: String = "hello") async {
        h.model.input = text
        await h.model.sendNow()
        await settle()
        deliver[deliver.count - 1](.session("s1"))
    }

    private func finishTurn(_ reply: String = "hi there") async {
        let emit = deliver[deliver.count - 1]
        emit(.assistant(reply))
        emit(.finished(error: nil))
        await settle()
    }

    private var notices: Int {
        session.items.filter { if case .notice(let text) = $0.kind { return text == SessionHandoff.systemLine } else { return false } }.count
    }

    // S1
    func testUnderTheLimitNothingHappens() async throws {
        _ = try transcript("s1", bytes: 50)
        await startTurn()
        await finishTurn()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(session.sessionID, "s1")
        XCTAssertEqual(notices, 0)
    }

    func testAnAgentWithoutAKnownTranscriptIsSkipped() async throws {
        session.setAgent(AgentCatalog.agent(id: "cursor")!)
        _ = try transcript("s1", bytes: 5_000)
        await startTurn()
        await finishTurn()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(notices, 0)
    }

    // S2
    func testItWaitsForTheRunningTurnAndRollsOverOnce() async throws {
        _ = try transcript("s1", bytes: 500)
        await startTurn()
        session.rolloverIfDue()
        await settle()
        XCTAssertEqual(turns.count, 1, "a turn is running, so nothing starts")
        await finishTurn()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].prompt, SessionHandoff.prompt)
        XCTAssertEqual(turns[1].resume, "s1")
        deliver[1](.assistant("We were fixing the parser."))
        deliver[1](.finished(error: nil))
        await settle()
        XCTAssertEqual(notices, 1)
        session.rolloverIfDue()
        await settle()
        XCTAssertEqual(turns.count, 2, "no second rollover")
        XCTAssertEqual(notices, 1)
    }

    func testItWaitsForAPendingPermission() async throws {
        _ = try transcript("s1", bytes: 50)
        await startTurn()
        await finishTurn()
        XCTAssertEqual(turns.count, 1)
        // The transcript grows past the limit while a permission request is open.
        _ = try transcript("s1", bytes: 500)
        var answered: ApprovalDecision?
        session.handlePermission(ACPToolCall(title: "Edit main.swift", kind: "edit")) { answered = $0 }
        XCTAssertEqual(session.approvals.count, 1)
        session.rolloverIfDue()
        await settle()
        XCTAssertEqual(turns.count, 1, "an approval is open, so the rollover waits")
        session.decide(session.approvals[0], allow: true)
        await settle()
        XCTAssertNotNil(answered)
        XCTAssertEqual(turns.count, 2, "answering it makes the chat idle, so the rollover starts")
        XCTAssertEqual(turns[1].prompt, SessionHandoff.prompt)
    }

    func testAQueuedMessageGoesBeforeTheRollover() async throws {
        _ = try transcript("s1", bytes: 500)
        await startTurn()
        session.submit("and one more thing", from: ChatOrigin(client: "test", ref: "1"))
        XCTAssertEqual(session.queue.count, 1)
        await finishTurn()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].prompt.contains("and one more thing"), true, "the queued message is the next turn, not the summary")
        XCTAssertEqual(notices, 0)
    }

    // S3
    func testTheFirstTurnOfTheNewSessionCarriesTheHandoff() async throws {
        _ = try transcript("s1", bytes: 500)
        await startTurn("hello")
        await finishTurn("first answer")
        deliver[1](.assistant("We were fixing the parser."))
        deliver[1](.finished(error: nil))
        await settle()
        XCTAssertNil(session.agentSessionID)
        let saved = ThreadStore.load("s1")
        XCTAssertNotNil(saved?.handoff, "a quit before the next message keeps the handoff")
        XCTAssertNil(saved?.activeSession)

        await startTurn2("next question")
        let turn = turns[2]
        XCTAssertNil(turn.resume)
        let preamble = try XCTUnwrap(turn.preamble)
        XCTAssertTrue(preamble.contains("memory_remember"), "the memory preamble")
        XCTAssertTrue(preamble.contains("We were fixing the parser."), "the summary")
        XCTAssertTrue(preamble.contains("User: hello"), "recent messages")
        XCTAssertTrue(preamble.contains("Assistant: first answer"))
        XCTAssertTrue(preamble.contains("memory_search"))
        XCTAssertLessThan(try XCTUnwrap(preamble.range(of: "We were fixing")).lowerBound, try XCTUnwrap(preamble.range(of: "User request:", options: .backwards)).lowerBound)

        deliver[2](.session("s2"))
        deliver[2](.assistant("ok"))
        deliver[2](.finished(error: nil))
        await settle()
        let stored = try XCTUnwrap(ThreadStore.load("s1"))
        XCTAssertEqual(stored.id, "s1", "the thread id never changes")
        XCTAssertEqual(stored.session, "s2")
        XCTAssertEqual(stored.previousSessions, ["s1"])
        XCTAssertNil(stored.handoff)
        XCTAssertEqual(session.sessionID, "s2")
        // The next turn resumes the new session and carries no preamble.
        await startTurn2("and again")
        XCTAssertEqual(turns[3].resume, "s2")
        XCTAssertNil(turns[3].preamble)
    }

    private func startTurn2(_ text: String) async {
        h.model.input = text
        await h.model.sendNow()
        await settle()
    }

    // S4
    func testAFailedSummaryFallsBackToTheMessages() async throws {
        _ = try transcript("s1", bytes: 500)
        await startTurn("fix the parser please")
        await finishTurn("Done, parser fixed.")
        deliver[1](.finished(error: "agent crashed"))
        await settle()
        XCTAssertEqual(notices, 1)
        await startTurn2("next")
        let preamble = try XCTUnwrap(turns[2].preamble)
        XCTAssertTrue(preamble.contains("could not write a summary"))
        XCTAssertTrue(preamble.contains("fix the parser please"))
        XCTAssertTrue(preamble.contains("Done, parser fixed."))
    }

    func testATimedOutSummaryFallsBackToTheMessages() async throws {
        session.handoffTimeout = .milliseconds(30)
        _ = try transcript("s1", bytes: 500)
        await startTurn("fix the parser please")
        await finishTurn("Done, parser fixed.")
        XCTAssertEqual(turns.count, 2)
        try await Task.sleep(for: .milliseconds(200))
        await settle()
        XCTAssertEqual(notices, 1)
        XCTAssertNil(session.agentSessionID)
        XCTAssertFalse(session.isRunning)
    }

    // S5
    func testAForkRunDeletesItsOwnCopyOnly() async throws {
        for failing in [false, true] {
            let ws = dir.appendingPathComponent("forkws")
            let folder = AgentTranscript.root.appendingPathComponent(AgentTranscript.slug(ws.path))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let main = folder.appendingPathComponent("main-1.jsonl")
            let other = folder.appendingPathComponent("other-run.jsonl")
            let copy = folder.appendingPathComponent("copy-\(failing).jsonl")
            for url in [main, other, copy] { try Data("{}".utf8).write(to: url) }
            let automation = Automation(id: "review", name: "Review", trigger: .init(type: "interval", minutes: 20, clock: "wall"),
                                        action: .init(type: "prompt", prompt: "review", agent: "claude", session: "fork"))
            let runner: AutomationSession.TurnRunner = { turn, emit in
                XCTAssertEqual(turn.fork, "main-1")
                emit(.session("copy-\(failing)"))
                emit(.finished(error: failing ? "boom" : nil))
            }
            let result = await AutomationSession.run(automation, prompt: "review", workspace: ws, spawner: UnsupportedProcessSpawner(),
                                                     turnRunner: runner, fork: "main-1")
            XCTAssertEqual(failing, { if case .failure = result { return true } else { return false } }())
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the run's copy is deleted (failing: \(failing))")
            XCTAssertTrue(FileManager.default.fileExists(atPath: main.path), "the main session is untouched")
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "another run's file is untouched")
        }
    }

    func testARunThatKeptTheMainSessionIdDeletesNothing() async throws {
        let ws = dir.appendingPathComponent("forkws2")
        let folder = AgentTranscript.root.appendingPathComponent(AgentTranscript.slug(ws.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let main = folder.appendingPathComponent("main-1.jsonl")
        try Data("{}".utf8).write(to: main)
        let automation = Automation(id: "review", name: "Review", trigger: .init(type: "interval", minutes: 20, clock: "wall"),
                                    action: .init(type: "prompt", prompt: "review", agent: "claude", session: "fork"))
        let runner: AutomationSession.TurnRunner = { _, emit in emit(.session("main-1")); emit(.finished(error: nil)) }
        _ = await AutomationSession.run(automation, prompt: "review", workspace: ws, spawner: UnsupportedProcessSpawner(),
                                        turnRunner: runner, fork: "main-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: main.path))
    }

    // S6
    func testRetentionDeletesOnlyOldPreviousSessions() throws {
        let now = Date()
        let folder = AgentTranscript.root.appendingPathComponent(AgentTranscript.slug(workspace.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func make(_ id: String, daysAgo: Double) throws -> URL {
            let url = folder.appendingPathComponent("\(id).jsonl")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let old = try make("old-prev", daysAgo: 20)
        let recent = try make("recent-prev", daysAgo: 3)
        let active = try make("active", daysAgo: 40)
        let unlisted = try make("unlisted", daysAgo: 90)
        let thread = ChatThread(id: "first", title: "t", workspace: workspace.path, updatedAt: now, items: [], agent: "claude",
                                session: "active", previousSessions: ["old-prev", "recent-prev", "active", "../escape", "missing"])
        let removed = AgentTranscript.prunePrevious(threads: [thread], days: 14, now: now)
        XCTAssertEqual(removed, ["old-prev"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for url in [recent, active, unlisted] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
    }

    func testRetentionSkipsASessionAnotherThreadStillRunsOn() throws {
        let now = Date()
        let folder = AgentTranscript.root.appendingPathComponent(AgentTranscript.slug(workspace.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("shared.jsonl")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: url.path)
        let a = ChatThread(id: "a", title: "a", workspace: workspace.path, updatedAt: now, items: [], agent: "claude",
                           session: "a2", previousSessions: ["shared"])
        let b = ChatThread(id: "shared", title: "b", workspace: workspace.path, updatedAt: now, items: [], agent: "claude")
        XCTAssertEqual(AgentTranscript.prunePrevious(threads: [a, b], days: 14, now: now), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(AgentTranscript.prunePrevious(threads: [a], days: 14, now: now, alsoActive: ["shared"]), [])
    }

    func testTheSlugMatchesClaudeCodesFolderNames() {
        XCTAssertEqual(AgentTranscript.slug("/Users/me/.band/worktrees/x"), "-Users-me--band-worktrees-x")
        XCTAssertNil(AgentTranscript.file(agent: "claude", workspace: "/tmp", session: "../x"))
        XCTAssertNil(AgentTranscript.file(agent: "cursor", workspace: "/tmp", session: "abc"))
    }

    func testConfigDefaultsAndLimits() {
        XCTAssertEqual(Config().chat.sessionRolloverMB, 50)
        XCTAssertEqual(Config().chat.sessionRetentionDays, 14)
        var config = Config()
        config.chat.sessionRolloverMB = 0
        config.chat.sessionRetentionDays = 9_999
        let fixed = config.sanitized()
        XCTAssertEqual(fixed.chat.sessionRolloverMB, 1)
        XCTAssertEqual(fixed.chat.sessionRetentionDays, 365)
    }

    // S9
    private func ownJob(agent: String) -> Automation {
        Automation(id: "mail", name: "Check mail", trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: "check", agent: agent, session: "own"))
    }

    func testAnOwnSessionRollsOverAndKeepsItsThread() async throws {
        let ws = dir.appendingPathComponent("ownws")
        let folder = AgentTranscript.root.appendingPathComponent(AgentTranscript.slug(ws.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var turns: [ACPTurn] = []
        var next = 0
        let runner: AutomationSession.TurnRunner = { turn, emit in
            turns.append(turn)
            if turn.prompt == SessionHandoff.prompt {
                emit(.assistant("Reported 3 mails, waiting on Anna."))
            } else {
                if turn.resume == nil { next += 1; emit(.session("own-\(next)")) }
                emit(.assistant("Checked."))
            }
            emit(.finished(error: nil))
        }
        func run() async {
            _ = await AutomationSession.run(ownJob(agent: "claude"), prompt: "check", workspace: ws, spawner: UnsupportedProcessSpawner(),
                                            turnRunner: runner, rolloverLimit: 100)
        }
        try Data(repeating: 0x61, count: 50).write(to: folder.appendingPathComponent("own-1.jsonl"))
        await run()
        await run()
        XCTAssertEqual(turns.map(\.resume), [nil, "own-1"], "under the limit the thread resumes")
        let first = try XCTUnwrap(ThreadStore.latest(automation: "mail"))
        XCTAssertEqual(first.id, "own-1")
        XCTAssertEqual(first.runs, 2)

        try Data(repeating: 0x61, count: 500).write(to: folder.appendingPathComponent("own-1.jsonl"))
        turns = []
        await run()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].prompt, SessionHandoff.prompt)
        XCTAssertEqual(turns[0].resume, "own-1")
        let fresh = turns[1]
        XCTAssertNil(fresh.resume)
        let preamble = try XCTUnwrap(fresh.preamble)
        XCTAssertTrue(preamble.contains("memory_remember"))
        XCTAssertTrue(preamble.contains("Reported 3 mails, waiting on Anna."))
        XCTAssertTrue(preamble.contains("Assistant: Checked."))
        let rolled = try XCTUnwrap(ThreadStore.latest(automation: "mail"))
        XCTAssertEqual(rolled.id, "own-1", "same thread")
        XCTAssertEqual(rolled.session, "own-2")
        XCTAssertEqual(rolled.previousSessions, ["own-1"])
        XCTAssertEqual(rolled.runs, 3)
        XCTAssertEqual(rolled.items.filter { $0.kind == .notice(SessionHandoff.systemLine) }.count, 1)

        // Next run resumes the new session: no handoff, no preamble.
        turns = []
        try Data(repeating: 0x61, count: 10).write(to: folder.appendingPathComponent("own-2.jsonl"))
        await run()
        XCTAssertEqual(turns.map(\.resume), ["own-2"])
        XCTAssertNil(turns[0].preamble)
    }

    func testAnOwnSessionOfAnAgentWithoutATranscriptKeepsTheRunLimit() async throws {
        let ws = dir.appendingPathComponent("ownws2")
        var resumes: [String?] = []
        let runner: AutomationSession.TurnRunner = { turn, emit in
            resumes.append(turn.resume)
            if turn.resume == nil { emit(.session("c-\(resumes.count)")) }
            emit(.assistant("ok")); emit(.finished(error: nil))
        }
        let job = ownJob(agent: "cursor")
        _ = await AutomationSession.run(job, prompt: "check", workspace: ws, spawner: UnsupportedProcessSpawner(), turnRunner: runner, rolloverLimit: 1)
        var thread = try XCTUnwrap(ThreadStore.latest(automation: "mail"))
        thread.runs = AutomationSession.ownRunLimit
        ThreadStore.save(thread)
        _ = await AutomationSession.run(job, prompt: "check", workspace: ws, spawner: UnsupportedProcessSpawner(), turnRunner: runner, rolloverLimit: 1)
        XCTAssertEqual(resumes, [nil, nil], "no rollover turn, and the run limit starts a fresh thread")
    }

    func testAnOwnRolloverWithAFailedSummaryUsesTheMessages() async throws {
        let ws = dir.appendingPathComponent("ownws3")
        let folder = AgentTranscript.root.appendingPathComponent(AgentTranscript.slug(ws.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var turns: [ACPTurn] = []
        let runner: AutomationSession.TurnRunner = { turn, emit in
            turns.append(turn)
            if turn.prompt == SessionHandoff.prompt { emit(.finished(error: "nope")); return }
            if turn.resume == nil { emit(.session("x-\(turns.count)")) }
            emit(.assistant("Found 2 invoices.")); emit(.finished(error: nil))
        }
        _ = await AutomationSession.run(ownJob(agent: "claude"), prompt: "check", workspace: ws, spawner: UnsupportedProcessSpawner(), turnRunner: runner, rolloverLimit: 100)
        try Data(repeating: 0x61, count: 500).write(to: folder.appendingPathComponent("x-1.jsonl"))
        _ = await AutomationSession.run(ownJob(agent: "claude"), prompt: "check", workspace: ws, spawner: UnsupportedProcessSpawner(), turnRunner: runner, rolloverLimit: 100)
        let preamble = try XCTUnwrap(turns.last?.preamble)
        XCTAssertTrue(preamble.contains("could not write a summary"))
        XCTAssertTrue(preamble.contains("Found 2 invoices."))
    }
}
