import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class BackgroundWorkTests: XCTestCase {
    private var session: ChatSession!
    private var h: ChatHarness!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        TestMemory.isolate()
        h = ChatHarness(); session = h.session
        session.backgroundClock = { [unowned self] in clock }
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func spawn(_ id: String, type: String, description: String, output: String? = nil, canStop: Bool = true) -> AsyncTaskUpdate {
        AsyncTaskUpdate(phase: .spawned, id: id, taskType: type, description: description, outputFile: output, canStop: canStop)
    }

    func testIdleChatShowsIdleAndNothingRan() {
        XCTAssertEqual(session.background.indicator, .idle)
        XCTAssertEqual(session.background.idleSummary(now: clock), "Nothing ran in the background.")
    }

    func testIdleListSaysWhatFinishedToday() {
        session.handleBackground(.asyncTask(spawn("t1", type: "shell", description: "Build")))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "t1", state: "completed")))
        XCTAssertEqual(session.background.indicator, .idle)
        XCTAssertEqual(session.background.idleSummary(now: clock), "1 finished today.")
    }

    func testTwoBackgroundAgentsShowAsTwoRunningRowsWithToolStepsAndTime() {
        session.handleBackground(.toolStarted(id: "a1", summary: "Research"))
        session.handleBackground(.toolStarted(id: "a2", summary: "Review"))
        clock.addTimeInterval(30)
        session.handleBackground(.subagentTool(parent: "a1", id: "s1", summary: "Ran `ls`", ok: nil))
        session.handleBackground(.subagentTool(parent: "a1", id: "s2", summary: "Read a.txt", ok: nil))
        session.handleBackground(.subagentTool(parent: "a2", id: "s3", summary: "Ran `swift test`", ok: nil))
        XCTAssertEqual(session.background.indicator, .running(2))
        let research = session.background.item("a1")
        XCTAssertEqual(research?.kind, .agent)
        XCTAssertEqual(research?.title, "Research")
        XCTAssertEqual(research?.now, "Read a.txt")
        XCTAssertEqual(research?.steps, 2)
        XCTAssertEqual(research?.elapsed(at: clock), 30)
        XCTAssertFalse(research?.canStop ?? true)
        XCTAssertEqual(research?.stopHint, "Can't stop an agent yet")
    }

    func testAgentRowFinishesWhenItsToolRowDoes() {
        session.handleBackground(.toolStarted(id: "a1", summary: "Research"))
        session.handleBackground(.subagentTool(parent: "a1", id: "s1", summary: "Ran `ls`", ok: nil))
        session.handleBackground(.toolFinished(id: "a1", ok: true))
        XCTAssertEqual(session.background.item("a1")?.state, .done)
        XCTAssertEqual(session.background.indicator, .idle)
    }

    func testAMainAgentToolWithoutChildrenIsNotBackgroundWork() {
        session.handleBackground(.toolStarted(id: "t", summary: "Ran `ls`"))
        session.handleBackground(.toolFinished(id: "t", ok: true))
        XCTAssertTrue(session.background.isEmpty)
    }

    func testShellRowShowsTheLastOutputLineAndTheTail() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString).out")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        session.handleBackground(.asyncTask(spawn("t1", type: "shell", description: "npm run dev", output: file.path)))
        await settle()
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .progress, id: "t1")))
        await settle()
        let row = session.background.item("t1")
        XCTAssertEqual(row?.kind, .shell)
        XCTAssertEqual(row?.now, "three")
        XCTAssertEqual(row?.lines, ["one", "two", "three"])
        XCTAssertEqual(row?.outputFile, file.path)
        XCTAssertTrue(row?.canStop ?? false)
    }

    func testStopSendsTheStopCallAndTheStoppedUpdateEndsTheRow() {
        var stopped: [String] = []
        session.asyncTaskStopper = { stopped.append($0) }
        session.handleBackground(.asyncTask(spawn("t1", type: "shell", description: "npm run dev")))
        session.handleBackground(.asyncTask(spawn("t2", type: "shell", description: "tail logs")))
        XCTAssertEqual(session.background.indicator, .running(2))
        session.stopBackground("t1")
        XCTAssertEqual(stopped, ["t1"])
        XCTAssertEqual(session.background.item("t1")?.state, .running, "the row changes when the agent reports it")
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "t1", state: "stopped")))
        XCTAssertEqual(session.background.item("t1")?.state, .stopped)
        XCTAssertEqual(session.background.indicator, .running(1))
    }

    func testMonitorHasNoStopAndShowsItsOutput() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString).out")
        try "watching\nchange in a.txt\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var stopped: [String] = []
        session.asyncTaskStopper = { stopped.append($0) }
        session.handleBackground(.asyncTask(spawn("m1", type: "monitor", description: "Watch the build", output: file.path, canStop: true)))
        await settle()
        let row = session.background.item("m1")
        XCTAssertEqual(row?.kind, .monitor)
        XCTAssertEqual(row?.title, "Watch the build")
        XCTAssertEqual(row?.now, "change in a.txt")
        XCTAssertFalse(row?.canStop ?? true)
        session.stopBackground("m1")
        XCTAssertTrue(stopped.isEmpty)
    }

    func testMonitorWithoutAnOutputFileShowsOnlyItsDescription() {
        session.handleBackground(.asyncTask(spawn("m1", type: "monitor", description: "Watch the build")))
        XCTAssertNil(session.background.item("m1")?.now)
        XCTAssertEqual(session.background.item("m1")?.title, "Watch the build")
    }

    func testWorkflowShowsSummaryAndLastToolWithNoPhaseAndCanStop() {
        var stopped: [String] = []
        session.asyncTaskStopper = { stopped.append($0) }
        session.handleBackground(.asyncTask(spawn("w1", type: "workflow", description: "Release checks")))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .progress, id: "w1", summary: "Checking changelog", lastToolName: "Read", toolCalls: 4)))
        let row = session.background.item("w1")
        XCTAssertEqual(row?.kind, .workflow)
        XCTAssertEqual(row?.now, "Checking changelog")
        XCTAssertEqual(row?.lines, ["Tool: Read"])
        XCTAssertEqual(row?.steps, 4)
        XCTAssertFalse((row?.lines ?? []).contains { $0.lowercased().contains("phase") })
        session.stopBackground("w1")
        XCTAssertEqual(stopped, ["w1"])
    }

    func testJobShowsWithItsLastStepAndStopGoesToTheJobStore() {
        var stopped: [String] = []
        session.jobStopper = { stopped.append($0) }
        let job = Job(id: "job-abc", title: "Update deps", prompt: "p", folder: "/tmp", agent: "claude", state: .running, lastStep: "Run swift test",
                      created: clock, started: clock)
        session.syncJobs([job])
        let row = session.background.item("job:job-abc")
        XCTAssertEqual(row?.kind, .job)
        XCTAssertEqual(row?.now, "Run swift test")
        session.stopBackground("job:job-abc")
        XCTAssertEqual(stopped, ["job-abc"])
        var stoppedJob = job
        stoppedJob.state = .stopped
        stoppedJob.ended = clock
        session.syncJobs([stoppedJob])
        XCTAssertEqual(session.background.item("job:job-abc")?.state, .stopped)
        XCTAssertEqual(session.background.indicator, .idle)
    }

    func testOldFinishedJobsAreLeftOut() {
        let old = clock.addingTimeInterval(-3 * 86_400)
        let job = Job(id: "job-old", title: "Old", prompt: "p", folder: "/tmp", agent: "claude", state: .done, created: old, started: old, ended: old)
        session.syncJobs([job])
        XCTAssertTrue(session.background.isEmpty)
    }

    func testStatePriorityIsFailedThenWaitingThenRunning() {
        session.handleBackground(.asyncTask(spawn("t1", type: "shell", description: "Build")))
        XCTAssertEqual(session.background.indicator, .running(1))
        let job = Job(id: "job-x", title: "Deploy", prompt: "p", folder: "/tmp", agent: "claude", state: .needsApproval, waitingFor: "Run `git push`",
                      created: clock, started: clock)
        session.syncJobs([job])
        XCTAssertEqual(session.background.indicator, .waiting(1))
        XCTAssertEqual(session.background.item("job:job-x")?.waitingFor, "Run `git push`")
        session.handleBackground(.asyncTask(spawn("t2", type: "shell", description: "Lint")))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "t2", state: "failed")))
        XCTAssertEqual(session.background.indicator, .failed(1))
        session.openBackground()
        XCTAssertEqual(session.background.indicator, .waiting(1))
    }

    func testAFailureShowsUntilTheListIsOpenedThenFallsBackToRunning() {
        session.handleBackground(.asyncTask(spawn("t1", type: "shell", description: "Build")))
        session.handleBackground(.asyncTask(spawn("t2", type: "shell", description: "Lint")))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "t2", summary: "exit 1", state: "failed")))
        XCTAssertEqual(session.background.indicator, .failed(1))
        session.openBackground()
        XCTAssertEqual(session.background.indicator, .running(1))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "t1", state: "completed")))
        XCTAssertEqual(session.background.indicator, .idle)
        XCTAssertEqual(session.background.item("t2")?.result, "exit 1")
    }

    func testClearFinishedKeepsRunningAndWaitingRows() {
        session.handleBackground(.asyncTask(spawn("run", type: "shell", description: "Server")))
        session.handleBackground(.asyncTask(spawn("done", type: "shell", description: "Build")))
        session.handleBackground(.asyncTask(spawn("bad", type: "shell", description: "Lint")))
        session.handleBackground(.asyncTask(spawn("stop", type: "shell", description: "Tail")))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "done", state: "completed")))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "bad", state: "failed")))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "stop", state: "stopped")))
        let waiting = Job(id: "job-w", title: "Deploy", prompt: "p", folder: "/tmp", agent: "claude", state: .needsApproval, created: clock, started: clock)
        session.syncJobs([waiting])
        session.clearFinishedBackground()
        XCTAssertEqual(Set(session.background.items.map(\.id)), ["run", "job:job-w"])
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "done", state: "completed")))
        XCTAssertEqual(session.background.items.count, 2, "a cleared row does not come back")
    }

    func testRunningOrderPutsNewestFirstAndFinishedLast() {
        session.handleBackground(.asyncTask(spawn("a", type: "shell", description: "A")))
        session.handleBackground(.asyncTask(AsyncTaskUpdate(phase: .state, id: "a", state: "completed")))
        session.handleBackground(.asyncTask(spawn("b", type: "shell", description: "B")))
        session.handleBackground(.asyncTask(spawn("c", type: "shell", description: "C")))
        XCTAssertEqual(session.background.ordered.map(\.id), ["c", "b", "a"])
    }

    func testAsyncTaskUpdateReadsTheWireShape() {
        let update: [String: Any] = ["sessionUpdate": "async_task_spawned", "asyncTaskId": "bx1", "taskType": "monitor", "description": "Watch", "canStop": true,
                                     "outputFilePath": "/tmp/x.out"]
        let parsed = AsyncTaskUpdate(update: update)
        XCTAssertEqual(parsed?.phase, .spawned)
        XCTAssertEqual(parsed?.id, "bx1")
        XCTAssertEqual(parsed?.taskType, "monitor")
        XCTAssertEqual(parsed?.outputFile, "/tmp/x.out")
        XCTAssertNil(AsyncTaskUpdate(update: ["sessionUpdate": "tool_call"]))
    }

    func testNewChatDropsChatWorkButKeepsJobs() {
        session.handleBackground(.asyncTask(spawn("t1", type: "shell", description: "Build")))
        let job = Job(id: "job-a", title: "Deploy", prompt: "p", folder: "/tmp", agent: "claude", state: .running, created: clock, started: clock)
        session.syncJobs([job])
        session.newChat()
        XCTAssertEqual(session.background.items.map(\.id), ["job:job-a"])
    }

    func testOutputTailKeepsTheLastLinesOfALargeFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: file) }
        try (1...5000).map { "line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let lines = OutputTail.lines(at: file.path, limit: 3)
        XCTAssertEqual(lines, ["line 4998", "line 4999", "line 5000"])
        XCTAssertNil(OutputTail.lines(at: "/nonexistent/path"))
    }
}
