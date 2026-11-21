import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class TaskBoardTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var api: TasksAPI!

    override func setUp() {
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        api = TasksAPI(store: TaskStore(database: APITestSupport.memoryDatabase(), now: { [unowned self] in clock }, keepDoneDays: { 30 }))
    }

    @discardableResult
    private func add(_ title: String, _ status: TaskStatus = .backlog, waitingOn: String? = nil, notes: String = "", labels: [String: String] = [:]) throws -> TaskItem {
        try api.create(CreateTaskRequest(title: title, notes: notes, status: status, source: .user, waitingOn: waitingOn, labels: labels))
    }

    private func ids(_ column: TaskColumn, label: String? = nil, query: String = "") -> [String] {
        (TaskBoard.columns(api.all, label: label, query: query, now: clock)[column] ?? []).map(\.title)
    }

    // S1
    func testTheViewModeIsSavedAndDefaultsToTheList() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ironpet-task-mode-\(UUID().uuidString)"))
        XCTAssertEqual(TaskViewMode.load(defaults), .list)
        TaskViewMode.board.save(defaults)
        XCTAssertEqual(TaskViewMode.load(defaults), .board)
        TaskViewMode.list.save(defaults)
        XCTAssertEqual(TaskViewMode.load(defaults), .list)
        defaults.set("kanban", forKey: TaskViewMode.key)
        XCTAssertEqual(TaskViewMode.load(defaults), .list, "an unknown value falls back to the list")
    }

    // S2
    func testTheFiveColumnsHoldTheListGroups() throws {
        try add("need", .needsYou)
        try add("run", .inProgress)
        try add("later", .backlog)
        try add("held", .inProgress, waitingOn: "Ana")
        try add("fresh", .backlog)
        let fresh = try XCTUnwrap(api.all.first { $0.title == "fresh" })
        try api.close(CloseTaskRequest(id: fresh.id))
        clock = clock.addingTimeInterval(8 * 86_400)
        let old = try add("old", .backlog)
        try api.close(CloseTaskRequest(id: old.id))
        clock = clock.addingTimeInterval(86_400)
        let recent = try add("recent", .backlog)
        try api.close(CloseTaskRequest(id: recent.id))

        XCTAssertEqual(ids(.needsYou), ["need"])
        XCTAssertEqual(ids(.inProgress), ["run"])
        XCTAssertEqual(ids(.backlog), ["later"])
        XCTAssertEqual(ids(.waiting), ["held"], "a waiting task is in Waiting on others whatever its status says")
        XCTAssertEqual(Set(ids(.done)), ["old", "recent"], "fresh closed 9 days ago, past the 7 day window")
    }

    func testTheLabelAndTheSearchNarrowEveryColumn() throws {
        try add("Ship release", .needsYou, labels: ["merge": "auto"])
        try add("Ship docs", .needsYou)
        try add("Reply to Ana", .inProgress, notes: "about the release", labels: ["merge": "auto"])
        try add("Held release", .backlog, waitingOn: "Bo", labels: ["merge": "auto"])
        XCTAssertEqual(Set(ids(.needsYou, label: "merge=auto")), ["Ship release"])
        XCTAssertEqual(Set(ids(.needsYou, query: "ship")), ["Ship release", "Ship docs"])
        XCTAssertEqual(ids(.inProgress, query: "release"), ["Reply to Ana"], "notes count")
        XCTAssertEqual(ids(.waiting, label: "merge=auto", query: "held"), ["Held release"])
        XCTAssertEqual(ids(.backlog, label: "nope=1"), [])
    }

    // S3
    func testDroppingOnAnotherColumnChangesTheStatus() throws {
        let task = try add("run", .inProgress)
        XCTAssertEqual(TaskBoard.drop(task.id, on: .needsYou, tasks: api), .moved)
        XCTAssertEqual(api.task(task.id)?.status, .needsYou)
        XCTAssertEqual(ids(.needsYou), ["run"])
        XCTAssertEqual(TaskBoard.drop(task.id, on: .needsYou, tasks: api), .unchanged, "already there")
        XCTAssertEqual(TaskBoard.drop("missing", on: .backlog, tasks: api), .unchanged)
    }

    // S4
    func testDroppingOnWaitingAsksForANameThenSetsIt() throws {
        let task = try add("run", .inProgress)
        XCTAssertEqual(TaskBoard.drop(task.id, on: .waiting, tasks: api), .needsName)
        XCTAssertNil(api.task(task.id)?.waitingOn, "nothing changes before a name is given")
        XCTAssertFalse(TaskBoard.hold(task.id, name: "   ", tasks: api))
        XCTAssertTrue(TaskBoard.hold(task.id, name: " Ana ", tasks: api))
        XCTAssertEqual(api.task(task.id)?.waitingOn, "Ana")
        XCTAssertEqual(api.task(task.id)?.status, .inProgress, "the store keeps the status of a waiting task")
        XCTAssertEqual(ids(.waiting), ["run"])
        XCTAssertEqual(TaskBoard.drop(task.id, on: .waiting, tasks: api), .unchanged)
    }

    func testDroppingAWaitingTaskOnAnotherColumnClearsWaitingOn() throws {
        let task = try add("held", .backlog, waitingOn: "Ana")
        XCTAssertEqual(TaskBoard.drop(task.id, on: .inProgress, tasks: api), .moved)
        XCTAssertNil(api.task(task.id)?.waitingOn)
        XCTAssertEqual(api.task(task.id)?.status, .inProgress)

        let same = try add("held too", .backlog, waitingOn: "Bo")
        XCTAssertEqual(TaskBoard.drop(same.id, on: .backlog, tasks: api), .moved, "a waiting backlog task dropped on Backlog stops waiting")
        XCTAssertNil(api.task(same.id)?.waitingOn)
    }

    func testAWaitingTaskDroppedOnDoneIsClosedWithoutAHolder() throws {
        let task = try add("held", .inProgress, waitingOn: "Ana")
        XCTAssertEqual(TaskBoard.drop(task.id, on: .done, tasks: api), .moved)
        XCTAssertEqual(api.task(task.id)?.status, .done)
        XCTAssertNil(api.task(task.id)?.waitingOn)
    }

    func testADoneTaskDroppedOnWaitingIsReopenedToTheBacklog() throws {
        let task = try add("finished", .backlog)
        try api.close(CloseTaskRequest(id: task.id))
        XCTAssertEqual(TaskBoard.drop(task.id, on: .waiting, tasks: api), .needsName)
        XCTAssertTrue(TaskBoard.hold(task.id, name: "Ana", tasks: api))
        XCTAssertEqual(api.task(task.id)?.status, .backlog)
        XCTAssertNil(api.task(task.id)?.closed)
        XCTAssertEqual(ids(.waiting), ["finished"])
    }

    // S5
    func testDroppingOnDoneClosesTheTaskLikeTheCheckButton() throws {
        let viaBoard = try add("a", .needsYou)
        let viaButton = try add("b", .needsYou)
        XCTAssertEqual(TaskBoard.drop(viaBoard.id, on: .done, tasks: api), .moved)
        try api.close(CloseTaskRequest(id: viaButton.id))
        let a = try XCTUnwrap(api.task(viaBoard.id)), b = try XCTUnwrap(api.task(viaButton.id))
        XCTAssertEqual(a.status, .done)
        XCTAssertEqual(a.closed, b.closed)
        XCTAssertEqual(api.history(viaBoard.id).map(\.kind), api.history(viaButton.id).map(\.kind))
        XCTAssertEqual(TaskBoard.drop(viaBoard.id, on: .done, tasks: api), .unchanged)
    }

    func testADoneTaskDroppedOnAnotherColumnIsReopened() throws {
        let task = try add("a", .needsYou)
        try api.close(CloseTaskRequest(id: task.id))
        XCTAssertEqual(TaskBoard.drop(task.id, on: .inProgress, tasks: api), .moved)
        XCTAssertEqual(api.task(task.id)?.status, .inProgress)
        XCTAssertNil(api.task(task.id)?.closed)
    }
}
