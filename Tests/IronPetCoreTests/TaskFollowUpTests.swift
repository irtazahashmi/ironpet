import XCTest
@testable import IronPetCore

/// Waiting for: when the user asked, and the five-working-day follow-up.
@MainActor
final class TaskFollowUpTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Monday 2026-11-23, 10:00 UTC.
    private let monday = Date(timeIntervalSince1970: 1_795_428_000)
    private var clock = Date()
    private var store: TaskStore!

    override func setUp() async throws {
        clock = monday
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, now: { [unowned self] in clock },
                          keepDoneDays: { 30 })
    }

    private func day(_ n: Int) -> Date { monday.addingTimeInterval(TimeInterval(n) * 86_400) }

    func testWorkingDaysSkipTheWeekend() async {
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2, "the fixture is a Monday")
        XCTAssertEqual(TaskFollowUp.workingDays(from: monday, to: day(4), calendar: calendar), 4, "Tuesday to Friday")
        XCTAssertEqual(TaskFollowUp.workingDays(from: monday, to: day(6), calendar: calendar), 4, "the weekend adds nothing")
        XCTAssertEqual(TaskFollowUp.workingDays(from: monday, to: day(7), calendar: calendar), 5, "the next Monday is the fifth")
        XCTAssertEqual(TaskFollowUp.workingDays(from: monday, to: day(400), calendar: calendar), 5, "the count stops at the limit")
    }

    func testAFollowUpIsDueAfterFiveWorkingDays() async throws {
        let task = try store.create(title: "Get the contract back", source: .user, waitingOn: "Ana", by: "test")
        XCTAssertEqual(task.askedAt, monday)
        XCTAssertFalse(task.followUpDue(now: day(6), calendar: calendar))
        XCTAssertTrue(task.followUpDue(now: day(7), calendar: calendar))
    }

    func testANewPersonRestartsTheClockAndNobodyClearsIt() async throws {
        let task = try store.create(title: "Get the contract back", source: .user, waitingOn: "Ana", by: "test")
        clock = day(3)
        XCTAssertEqual(try store.update(task.id, waitingOn: .some("Sam"), by: "test").askedAt, day(3))
        clock = day(4)
        XCTAssertNil(try store.update(task.id, waitingOn: .some(nil), by: "test").askedAt)
    }

    func testOwnWorkAndDoneTasksNeverNeedAFollowUp() async throws {
        let own = try store.create(title: "Write the report", source: .user, by: "test")
        XCTAssertNil(own.askedAt)
        XCTAssertFalse(own.followUpDue(now: day(30), calendar: calendar))
        let done = try store.create(title: "Old ask", status: .done, source: .user, waitingOn: "Ana", by: "test")
        XCTAssertFalse(done.followUpDue(now: day(30), calendar: calendar))
    }

    func testAgentsSetAskedAtAndSeeWhenAFollowUpIsDue() async throws {
        let api = TasksAPI(store: store)
        let args: [String: Any] = ["title": "Hear back from the landlord", "waiting_on": "Landlord", "asked_at": "2020-01-06",
                                   "origin": ["kind": "chat", "ref": "t1", "reason": "asked"]]
        let created = try XCTUnwrap(try TaskJSON.call(api, "create", args, by: "agent:mcp").get() as? [String: Any])
        XCTAssertNotNil(created["asked_at"])
        XCTAssertEqual(created["follow_up_due"] as? Bool, true, "asked years ago")

        let id = try XCTUnwrap(created["id"] as? String)
        let fresh = try XCTUnwrap(try TaskJSON.call(api, "update", ["id": id, "changes": ["asked_at": ISO8601DateFormatter().string(from: Date())]],
                                                    by: "agent:mcp").get() as? [String: Any])
        XCTAssertNil(fresh["follow_up_due"], "the user just followed up")
    }

    func testParkedOrDeferredWaitingTasksGetNoFollowUp() async throws {
        let someday = try store.create(title: "Maybe hear from the agency", status: .someday, source: .user, waitingOn: "Agency", by: "test")
        XCTAssertFalse(someday.followUpDue(now: day(30), calendar: calendar))
        let deferred = try store.create(title: "Quote from the builder", source: .user, waitingOn: "Builder", deferUntil: day(60), by: "test")
        XCTAssertFalse(deferred.followUpDue(now: day(30), calendar: calendar))
    }

    func testAskedAtOnlyAppliesWhileTheTaskWaits() async throws {
        let own = try store.create(title: "Write the report", source: .user, askedAt: day(-10), by: "test")
        XCTAssertNil(own.askedAt, "nobody to follow up with")
        XCTAssertNil(try store.update(own.id, askedAt: day(-5), by: "test").askedAt)
    }

    func testMigration583StartsTheClockOfTasksAlreadyWaiting() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-583-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        let before = Database.open(path: file, migrations: AppMigrations.all.filter { $0.version < 583 }).database
        try before.write { db in
            try db.execute("""
                INSERT INTO task_items(id, title, notes, status, source, created, updated, waiting_on)
                VALUES('a', 'Contract', '', 'backlog', 'user', 1, 1700000000, 'Ana'), ('b', 'Report', '', 'backlog', 'user', 1, 1700000000, NULL)
                """)
        }
        let migrated = Database.open(path: file, migrations: AppMigrations.all).database
        let older = TaskStore(database: migrated, keepDoneDays: { 30 })
        XCTAssertEqual(older.task("a")?.askedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(older.task("b")?.askedAt)
    }

    func testFollowedUpStartsTheCountAgain() async throws {
        let task = try store.create(title: "Get the contract back", source: .user, waitingOn: "Ana", by: "test")
        clock = day(7)
        XCTAssertTrue(try XCTUnwrap(store.task(task.id)).followUpDue(now: clock, calendar: calendar))
        let again = try TaskEdits.markFollowedUp(task.id, in: TasksAPI(store: store), now: clock)
        XCTAssertEqual(again.askedAt, day(7))
        XCTAssertFalse(again.followUpDue(now: day(8), calendar: calendar))
    }
}
