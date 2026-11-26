import XCTest
@testable import IronPetCore

/// GTD projects: their tasks, the next-action rule, review intervals and the agent tools.
@MainActor
final class TaskProjectsTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var store: TaskStore!
    private var api: TasksAPI!

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, now: { [unowned self] in clock },
                          keepDoneDays: { 30 })
        api = TasksAPI(store: store)
    }

    private func call(_ op: String, _ args: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(try TaskJSON.call(api, op, args, by: "agent:mcp").get() as? [String: Any])
    }

    func testAProjectWithoutANextActionIsStalled() async throws {
        let site = try api.upsertProject(id: nil, title: "Launch the new site", outcome: "The new site is live")
        XCTAssertEqual(api.stalledProjects(now: clock).map(\.id), [site.id], "a new project has no step yet")

        let step = try store.create(title: "Write the copy", source: .user, project: site.id, by: "test")
        XCTAssertEqual(api.nextActions(of: site.id, now: clock).map(\.id), [step.id])
        XCTAssertTrue(api.stalledProjects(now: clock).isEmpty)
    }

    func testWaitingDeferredAndDoneStepsAreNotNextActions() async throws {
        let site = try api.upsertProject(id: nil, title: "Launch the new site")
        _ = try store.create(title: "Logo from Ana", source: .user, waitingOn: "Ana", project: site.id, by: "test")
        _ = try store.create(title: "Press release", source: .user, deferUntil: clock.addingTimeInterval(86_400), project: site.id, by: "test")
        _ = try store.create(title: "Pick a host", status: .done, source: .user, project: site.id, by: "test")
        _ = try store.create(title: "Maybe a blog", status: .someday, source: .user, project: site.id, by: "test")
        XCTAssertEqual(api.stalledProjects(now: clock).map(\.id), [site.id])
    }

    func testOnlyActiveProjectsCanBeStalled() async throws {
        _ = try api.upsertProject(id: nil, title: "Learn the cello", status: .someday)
        _ = try api.upsertProject(id: nil, title: "Old launch", status: .done)
        XCTAssertTrue(api.stalledProjects(now: clock).isEmpty)
    }

    func testAReviewIntervalComesDueAndReviewingResetsIt() async throws {
        let site = try api.upsertProject(id: nil, title: "Launch the new site", reviewDays: 7)
        XCTAssertFalse(site.isDueForReview(now: clock))
        clock = clock.addingTimeInterval(7 * 86_400)
        XCTAssertTrue(try XCTUnwrap(api.project(site.id)).isDueForReview(now: clock))
        let reviewed = try api.upsertProject(id: site.id, title: nil, markReviewed: true)
        XCTAssertFalse(reviewed.isDueForReview(now: clock))
    }

    func testATaskCannotJoinAProjectThatDoesNotExist() async {
        XCTAssertThrowsError(try store.create(title: "Orphan", source: .user, project: "nope", by: "test"))
    }

    func testAgentsCreateListAndLinkProjects() async throws {
        let created = try call("projects_upsert", ["title": "Move house", "outcome": "We live in the new flat", "area": "Home", "review_days": 7])
        let id = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(created["area"] as? String, "Home")

        var listed = try XCTUnwrap(try call("projects_list", [:])["projects"] as? [[String: Any]])
        XCTAssertEqual(listed.first?["stalled"] as? Bool, true)

        let task = try call("create", ["title": "Book the movers", "project": id, "origin": ["kind": "chat", "ref": "t1", "reason": "asked"]])
        XCTAssertEqual(task["project"] as? String, id)
        listed = try XCTUnwrap(try call("projects_list", [:])["projects"] as? [[String: Any]])
        XCTAssertEqual(listed.first?["stalled"] as? Bool, false)
        XCTAssertEqual((listed.first?["next_actions"] as? [[String: Any]])?.first?["title"] as? String, "Book the movers")

        let taskID = try XCTUnwrap(task["id"] as? String)
        let unlinked = try call("update", ["id": taskID, "changes": ["project": NSNull()]])
        XCTAssertNil(unlinked["project"])

        let cleared = try call("projects_upsert", ["id": id, "area": NSNull(), "status": "done"])
        XCTAssertNil(cleared["area"])
        XCTAssertTrue(try XCTUnwrap(try call("projects_list", [:])["projects"] as? [[String: Any]]).isEmpty, "done projects are left out")
        XCTAssertEqual((try call("projects_list", ["status": "done"])["projects"] as? [[String: Any]])?.count, 1)
    }

    func testBadProjectInputIsRefused() async {
        XCTAssertThrowsError(try TaskJSON.call(api, "projects_upsert", ["outcome": "No title"], by: "agent:mcp").get())
        XCTAssertThrowsError(try TaskJSON.call(api, "projects_upsert", ["title": "X", "review_days": 0], by: "agent:mcp").get())
        XCTAssertThrowsError(try TaskJSON.call(api, "projects_upsert", ["title": "X", "status": "paused"], by: "agent:mcp").get())
    }

    func testTheProjectToolsRunWithoutAPrompt() async {
        XCTAssertTrue(ApprovalRules.ownTaskTools.isSuperset(of: ["task_projects_list", "task_projects_upsert"]))
    }

    func testProjectsSurviveAReload() async throws {
        let sales = try api.upsertGoal(id: nil, title: "Grow sales")
        let site = try api.upsertProject(id: nil, title: "Launch the new site", area: "Work", goal: .some(sales.id))
        store.reload()
        XCTAssertEqual(api.project(site.id), site)
    }

    func testAcceptingAProposedNextStepUnstallsTheProject() async throws {
        let site = try api.upsertProject(id: nil, title: "Launch the new site")
        let proposal = try call("suggest", ["id": "next-1", "title": "Draft the homepage copy", "project": site.id,
                                            "origin": ["kind": "agent", "ref": "review", "reason": "stalled project"]])
        let suggestion = try XCTUnwrap(proposal["suggestion"] as? [String: Any])
        XCTAssertEqual(suggestion["project"] as? String, site.id)
        let task = try store.accept(try XCTUnwrap(suggestion["id"] as? String))
        XCTAssertEqual(task.project, site.id)
        XCTAssertTrue(api.stalledProjects(now: clock).isEmpty)
    }

    func testASuggestionCannotNameAProjectThatDoesNotExist() async {
        let args: [String: Any] = ["id": "x", "title": "Y", "project": "nope", "origin": ["kind": "agent", "ref": "r", "reason": "r"]]
        XCTAssertThrowsError(try TaskJSON.call(api, "suggest", args, by: "agent:mcp").get())
    }

    func testAnUnknownProjectIdIsRefusedInsteadOfCreatingADuplicate() async throws {
        _ = try api.upsertProject(id: nil, title: "Launch the new site")
        XCTAssertThrowsError(try TaskJSON.call(api, "projects_upsert", ["id": "lanch-the-new-site", "title": "Launch"], by: "agent:mcp").get())
        XCTAssertThrowsError(try TaskJSON.call(api, "projects_upsert", ["id": 7, "title": "Launch"], by: "agent:mcp").get())
        XCTAssertThrowsError(try TaskJSON.call(api, "projects_upsert", ["id": " ", "title": "Launch"], by: "agent:mcp").get())
        XCTAssertEqual(api.projects.count, 1)
    }
}
