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

    func testWorkingDaysSkipTheWeekend() {
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2, "the fixture is a Monday")
        XCTAssertEqual(TaskFollowUp.workingDays(from: monday, to: day(4), calendar: calendar), 4, "Tuesday to Friday")
        XCTAssertEqual(TaskFollowUp.workingDays(from: monday, to: day(6), calendar: calendar), 4, "the weekend adds nothing")
        XCTAssertEqual(TaskFollowUp.workingDays(from: monday, to: day(7), calendar: calendar), 5, "the next Monday is the fifth")
        XCTAssertEqual(TaskFollowUp.workingDays(from: monday, to: day(400), calendar: calendar), 5, "the count stops at the limit")
    }

    func testAFollowUpIsDueAfterFiveWorkingDays() throws {
        let task = try store.create(title: "Get the contract back", source: .user, waitingOn: "Ana", by: "test")
        XCTAssertEqual(task.askedAt, monday)
        XCTAssertFalse(task.followUpDue(now: day(6), calendar: calendar))
        XCTAssertTrue(task.followUpDue(now: day(7), calendar: calendar))
    }

    func testANewPersonRestartsTheClockAndNobodyClearsIt() throws {
        let task = try store.create(title: "Get the contract back", source: .user, waitingOn: "Ana", by: "test")
        clock = day(3)
        XCTAssertEqual(try store.update(task.id, waitingOn: .some("Sam"), by: "test").askedAt, day(3))
        clock = day(4)
        XCTAssertNil(try store.update(task.id, waitingOn: .some(nil), by: "test").askedAt)
    }

    func testOwnWorkAndDoneTasksNeverNeedAFollowUp() throws {
        let own = try store.create(title: "Write the report", source: .user, by: "test")
        XCTAssertNil(own.askedAt)
        XCTAssertFalse(own.followUpDue(now: day(30), calendar: calendar))
        let done = try store.create(title: "Old ask", status: .done, source: .user, waitingOn: "Ana", by: "test")
        XCTAssertFalse(done.followUpDue(now: day(30), calendar: calendar))
    }

    func testAgentsSetAskedAtAndSeeWhenAFollowUpIsDue() throws {
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
}
