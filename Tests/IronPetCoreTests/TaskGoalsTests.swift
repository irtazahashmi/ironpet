import XCTest
@testable import IronPetCore

/// GTD's horizons 2 and 3: areas, goals and their key results.
@MainActor
final class TaskGoalsTests: XCTestCase {
    private var store: TaskStore!
    private var api: TasksAPI!

    override func setUp() async throws {
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, keepDoneDays: { 30 })
        api = TasksAPI(store: store)
    }

    private func call(_ op: String, _ args: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(try TaskJSON.call(api, op, args, by: "agent:mcp").get() as? [String: Any])
    }

    func testKeyResultProgressRunsFromStartToTargetInEitherDirection() async {
        func result(_ start: Double, _ target: Double, _ current: Double) -> TaskKeyResult {
            TaskKeyResult(id: "k", goal: "g", metric: "m", start: start, target: target, current: current, unit: nil, due: nil, source: nil, updated: Date())
        }
        XCTAssertEqual(result(10, 25, 17.5).progress, 0.5)
        XCTAssertEqual(result(20, 5, 15).progress, 1.0 / 3.0, accuracy: 0.0001, "a lower target, such as open bugs")
        XCTAssertEqual(result(0, 10, 14).progress, 1, "beyond the target counts as done")
        XCTAssertEqual(result(0, 10, -3).progress, 0)
        XCTAssertEqual(result(5, 5, 5).progress, 1)
    }

    func testAGoalsProgressIsTheMeanOfItsKeyResults() async throws {
        let goal = try api.upsertGoal(id: nil, title: "Grow the business")
        XCTAssertNil(api.progress(of: goal.id), "no key results, no progress")
        let revenue = try api.upsertKeyResult(id: nil, goal: goal.id, metric: "Monthly revenue", start: 10, target: 20, unit: "k EUR")
        _ = try api.upsertKeyResult(id: nil, goal: goal.id, metric: "Customers", start: 0, target: 10, current: 10)
        XCTAssertEqual(revenue.current, 10, "current starts at start")
        XCTAssertEqual(api.progress(of: goal.id), 0.5)
        _ = try api.upsertKeyResult(id: revenue.id, current: 15)
        XCTAssertEqual(api.progress(of: goal.id), 0.75)
    }

    func testLinksMustPointAtThingsThatExist() async throws {
        XCTAssertThrowsError(try api.upsertGoal(id: nil, title: "Run a marathon", area: .some("health")))
        let health = try api.upsertArea(id: nil, title: "Health")
        let goal = try api.upsertGoal(id: nil, title: "Run a marathon", area: .some(health.id))
        XCTAssertEqual(goal.area, health.id)
        XCTAssertThrowsError(try api.upsertKeyResult(id: nil, goal: "nope", metric: "Km a week", start: 0, target: 40))
        XCTAssertThrowsError(try api.upsertKeyResult(id: nil, goal: goal.id, metric: "Km a week"), "start and target are required")
        XCTAssertThrowsError(try api.upsertGoal(id: "nope", title: "X"))
    }

    func testProjectsServeAGoalThroughTheirGoalField() async throws {
        let goal = try api.upsertGoal(id: nil, title: "Grow the business")
        let site = try api.upsertProject(id: nil, title: "Launch the new site", goal: .some(goal.id))
        _ = try api.upsertProject(id: nil, title: "Move house")
        XCTAssertEqual(api.projects(serving: goal.id).map(\.id), [site.id])
    }

    func testAgentsBuildAndReadTheHorizons() async throws {
        let area = try call("areas_upsert", ["title": "Work"])
        let goal = try call("goals_upsert", ["title": "Ship 2.0", "why": "Customers asked for it", "area": try XCTUnwrap(area["id"])])
        let goalID = try XCTUnwrap(goal["id"] as? String)
        let result = try call("key_results_upsert", ["goal": goalID, "metric": "Features done", "start": 0, "target": 8, "unit": "features"])
        _ = try call("key_results_upsert", ["id": try XCTUnwrap(result["id"]), "current": 2])

        let listed = try call("goals_list", [:])
        let first = try XCTUnwrap((listed["goals"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["progress"] as? Double, 0.25)
        XCTAssertEqual((first["key_results"] as? [[String: Any]])?.first?["current"] as? Double, 2)
        XCTAssertEqual((listed["areas"] as? [[String: Any]])?.first?["title"] as? String, "Work")

        _ = try call("goals_upsert", ["id": goalID, "status": "achieved"])
        XCTAssertTrue(try XCTUnwrap(try call("goals_list", [:])["goals"] as? [[String: Any]]).isEmpty)
        XCTAssertEqual((try call("goals_list", ["include_closed": true])["goals"] as? [[String: Any]])?.count, 1)
    }

    func testBadNumbersAreRefused() async throws {
        let goal = try api.upsertGoal(id: nil, title: "Read more")
        XCTAssertThrowsError(try TaskJSON.call(api, "key_results_upsert", ["goal": goal.id, "metric": "Books", "start": "zero", "target": 12],
                                               by: "agent:mcp").get())
        XCTAssertThrowsError(try TaskJSON.call(api, "key_results_upsert", ["goal": goal.id, "metric": "Books", "start": true, "target": 12],
                                               by: "agent:mcp").get())
    }

    func testTheHorizonsSurviveAReload() async throws {
        let goal = try api.upsertGoal(id: nil, title: "Read more", why: "Calmer evenings")
        let result = try api.upsertKeyResult(id: nil, goal: goal.id, metric: "Books", start: 0, target: 12, source: .some("Goodreads"))
        store.reload()
        XCTAssertEqual(api.goals, [goal])
        XCTAssertEqual(api.keyResults(of: goal.id), [result])
    }

    func testZeroAndOneFromJSONAreNumbersButABooleanIsNot() async throws {
        let goal = try api.upsertGoal(id: nil, title: "Read more")
        func decoded(_ json: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let made = try XCTUnwrap(try TaskJSON.call(api, "key_results_upsert", try decoded(#"{"goal":"\#(goal.id)","metric":"Books","start":0,"target":1}"#),
                                                   by: "agent:mcp").get() as? [String: Any])
        XCTAssertEqual(made["progress"] as? Double, 0)
        XCTAssertThrowsError(try TaskJSON.call(api, "key_results_upsert", try decoded(#"{"goal":"\#(goal.id)","metric":"Pages","start":true,"target":1}"#),
                                               by: "agent:mcp").get())
    }

    func testAProjectsGoalMustExistAndAKeyResultCannotMove() async throws {
        XCTAssertThrowsError(try api.upsertProject(id: nil, title: "Launch", goal: .some("Grow the business")), "a title is not an id")
        let goal = try api.upsertGoal(id: nil, title: "Grow the business")
        let other = try api.upsertGoal(id: nil, title: "Read more")
        let result = try api.upsertKeyResult(id: nil, goal: goal.id, metric: "Revenue", start: 0, target: 10)
        XCTAssertThrowsError(try api.upsertKeyResult(id: result.id, goal: other.id, current: 2))
    }

    func testAreaTitlesAreUniqueWithoutRegardToCase() async throws {
        let work = try api.upsertArea(id: nil, title: "Work")
        XCTAssertThrowsError(try api.upsertArea(id: nil, title: "work"))
        let home = try api.upsertArea(id: nil, title: "Home")
        XCTAssertThrowsError(try api.upsertArea(id: home.id, title: "WORK"))
        XCTAssertEqual(try api.upsertArea(id: work.id, title: "Work").title, "Work", "renaming to its own title is fine")
    }

    func testDeletingAKeyResultLeavesTheOthers() async throws {
        let goal = try api.upsertGoal(id: nil, title: "Grow the business")
        let wrong = try api.upsertKeyResult(id: nil, goal: goal.id, metric: "Duplicate", start: 0, target: 10)
        _ = try api.upsertKeyResult(id: nil, goal: goal.id, metric: "Revenue", start: 0, target: 10, current: 10)
        XCTAssertEqual(api.progress(of: goal.id), 0.5)
        _ = try TaskJSON.call(api, "key_results_delete", ["id": wrong.id], by: "agent:mcp").get()
        XCTAssertEqual(api.progress(of: goal.id), 1)
        XCTAssertThrowsError(try api.deleteKeyResult(wrong.id))
    }

    func testGoalsGroupByAreaThenNoArea() async throws {
        let work = try api.upsertArea(id: nil, title: "Work")
        let health = try api.upsertArea(id: nil, title: "Health")
        let ship = try api.upsertGoal(id: nil, title: "Ship 2.0", area: .some(work.id))
        let run = try api.upsertGoal(id: nil, title: "Run a half marathon", area: .some(health.id))
        let read = try api.upsertGoal(id: nil, title: "Read more")
        let groups = api.goalGroups(api.goals)
        XCTAssertEqual(groups.map(\.title), ["Health", "Work", "No area"])
        XCTAssertEqual(groups.map(\.id), [health.id, work.id, ""])
        XCTAssertEqual(groups.map { $0.goals.map(\.id) }, [[run.id], [ship.id], [read.id]])
        XCTAssertEqual(api.goalGroups([read]).map(\.title), ["No area"], "areas without goals are left out")
    }
}
