import XCTest
@testable import IronPet
@testable import IronPetCore
import enum IronPetKit.QuickFilterNode

@MainActor
final class SomedayDeferTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var api: IronPetAPI!
    private var tasks: TasksAPI { api.tasks }

    override func setUp() {
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        api = APITestSupport.makeAPI(now: { [unowned self] in clock })
    }

    @discardableResult
    private func add(_ title: String, _ status: TaskStatus = .backlog, waitingOn: String? = nil, deferUntil: Date? = nil) throws -> TaskItem {
        try tasks.create(CreateTaskRequest(title: title, status: status, source: .user, waitingOn: waitingOn, deferUntil: deferUntil))
    }

    private func titles(_ column: TaskColumn) -> [String] {
        (TaskBoard.columns(tasks.all, filter: nil, query: "", now: clock)[column] ?? []).map(\.title)
    }

    // MARK: Someday

    func testSomedayHasItsOwnColumnEvenWhenSomeoneHoldsTheTask() throws {
        try add("Learn Rust", .someday)
        try add("Ask Ana about the cabin", .someday, waitingOn: "Ana")
        try add("Ship it")
        XCTAssertEqual(Set(titles(.someday)), ["Learn Rust", "Ask Ana about the cabin"])
        XCTAssertEqual(titles(.backlog), ["Ship it"])
        XCTAssertTrue(titles(.waiting).isEmpty)
    }

    func testSomedaySortsAfterOpenWorkAndBeforeDone() throws {
        try add("Finished", .done)
        try add("Maybe", .someday)
        try add("Now", .needsYou)
        XCTAssertEqual(tasks.all.map(\.title), ["Now", "Maybe", "Finished"])
    }

    func testDroppingOnSomedaySetsTheStatusAndClearsWhoHoldsIt() throws {
        let task = try add("Plan the trip", waitingOn: "Sam")
        XCTAssertEqual(TaskBoard.drop(task.id, on: .someday, tasks: tasks), .moved)
        XCTAssertEqual(tasks.task(task.id)?.status, .someday)
        XCTAssertNil(tasks.task(task.id)?.waitingOn)
    }

    // MARK: Defer until

    func testADeferredTaskIsInNoColumnUntilItsDayThenComesBack() throws {
        let later = clock.addingTimeInterval(2 * 86_400)
        try add("Renew the passport", .needsYou, deferUntil: later)
        try add("Today's thing")
        XCTAssertEqual(titles(.needsYou), [])
        XCTAssertEqual(TaskBoard.deferred(tasks.all, filter: nil, query: "", now: clock).map(\.title), ["Renew the passport"])

        clock = later
        XCTAssertEqual(titles(.needsYou), ["Renew the passport"], "the tickler returns it on its day")
        XCTAssertTrue(TaskBoard.deferred(tasks.all, filter: nil, query: "", now: clock).isEmpty)
    }

    func testDeferredSoonestFirstAndNarrowedBySearch() throws {
        try add("Second", deferUntil: clock.addingTimeInterval(2 * 86_400))
        try add("First", deferUntil: clock.addingTimeInterval(86_400))
        XCTAssertEqual(TaskBoard.deferred(tasks.all, filter: nil, query: "", now: clock).map(\.title), ["First", "Second"])
        XCTAssertEqual(TaskBoard.deferred(tasks.all, filter: nil, query: "sec", now: clock).map(\.title), ["Second"])
    }

    func testADeferredTaskDoesNotNeedTheUserAndADoneOneIsNeverDeferred() throws {
        let far = clock.addingTimeInterval(30 * 86_400)
        let deferred = try add("Later", .needsYou, deferUntil: far)
        XCTAssertFalse(deferred.needsUser(now: clock))
        XCTAssertTrue(deferred.needsUser(now: far), "it needs the user again on its day")
        XCTAssertEqual(api.tasks.activeCount, 0)
        let done = try add("Over", .done, deferUntil: far)
        XCTAssertFalse(done.isDeferred())
    }

    func testDeferUntilIsSavedAndClearedThroughTheTaskPage() throws {
        let task = try add("Call the bank")
        let day = clock.addingTimeInterval(86_400)
        _ = try TaskEdits.setDeferUntil(day, of: task.id, in: tasks)
        XCTAssertEqual(tasks.task(task.id)?.deferUntil, day)
        XCTAssertTrue(try tasks.get(task.id).history.contains { $0.detail.hasPrefix("defer until:") })
        _ = try TaskEdits.setDeferUntil(nil, of: task.id, in: tasks)
        XCTAssertNil(tasks.task(task.id)?.deferUntil)
    }

    // MARK: Agents and the phone

    func testAgentsSetSomedayAndDeferUntilAndSeeThemInTheJSON() throws {
        let args: [String: Any] = ["title": "Visit Lisbon", "status": "someday", "defer_until": "2027-03-01",
                                   "origin": ["kind": "chat", "ref": "t1", "reason": "asked"]]
        let created = try TaskJSON.call(tasks, "create", args, by: "agent:mcp").get() as? [String: Any]
        XCTAssertEqual(created?["status"] as? String, "someday")
        XCTAssertNotNil(created?["defer_until"])
        let id = try XCTUnwrap(created?["id"] as? String)

        let cleared = try TaskJSON.call(tasks, "update", ["id": id, "changes": ["defer_until": NSNull()]], by: "agent:mcp").get() as? [String: Any]
        XCTAssertNil(cleared?["defer_until"])
    }

    func testThePhoneGetsSomedayTasksOnlyWhenItAsks() throws {
        try add("Maybe", .someday)
        try add("Now")
        let remote = RemoteTasks(api: api, by: "remote:test")
        func listed(_ query: [String: [String]]) throws -> [String] {
            ((try remote.list(query: query)["tasks"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
        }
        XCTAssertEqual(try listed([:]), ["Now"], "an older phone cannot decode someday")
        XCTAssertEqual(Set(try listed(["include_someday": ["1"]])), ["Now", "Maybe"])
        XCTAssertEqual(try listed(["status": ["someday"]]), ["Maybe"])
    }

    func testQuickFiltersCanAskForSomeday() throws {
        XCTAssertEqual(try QuickFilterNode.parse(["status": "someday"]), .status(["someday"]))
    }

    func testSingleTaskAnswersSendSomedayAsBacklogToThePhone() throws {
        let task = try add("Maybe", .someday)
        let remote = RemoteTasks(api: api, by: "remote:test")
        let detail = try remote.get(task.id)
        XCTAssertEqual(detail["status"] as? String, "backlog", "the detail answer is the task's fields plus its history")
        XCTAssertEqual(tasks.task(task.id)?.status, .someday, "the Mac keeps the status")
    }

    func testAnUpdateFromAnOlderClientDecodesWithoutClearDeferUntil() throws {
        let json = #"{"id":"a","by":"user","clearDue":false,"labels":{},"removeLabels":[],"status":"in_progress"}"#
        let request = try JSONDecoder().decode(UpdateTaskRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.clearDeferUntil)
        XCTAssertEqual(request.status, .inProgress)
    }

    func testABadDeferUntilNamesTheField() {
        let args: [String: Any] = ["title": "X", "defer_until": "soon", "origin": ["kind": "chat", "ref": "t1", "reason": "asked"]]
        guard case .failure(let error) = TaskJSON.call(tasks, "create", args, by: "agent:mcp") else { return XCTFail("refused") }
        XCTAssertTrue(error.message.hasPrefix("defer_until"), error.message)
    }

    func testNextActionsForAgentsLeavesOutDeferredTasks() throws {
        try add("Now", .needsYou)
        try add("In March", .needsYou, deferUntil: Date().addingTimeInterval(60 * 86_400))
        let listed = try TaskJSON.call(tasks, "list", ["filter": "next-actions"], by: "agent:mcp").get() as? [String: Any]
        XCTAssertEqual((listed?["tasks"] as? [[String: Any]])?.compactMap { $0["title"] as? String }, ["Now"])
        let all = try TaskJSON.call(tasks, "list", [:], by: "agent:mcp").get() as? [String: Any]
        XCTAssertEqual((all?["tasks"] as? [[String: Any]])?.count, 2, "a plain list still shows everything")
    }
}
