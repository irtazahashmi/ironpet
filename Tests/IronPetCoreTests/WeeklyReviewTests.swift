import XCTest
@testable import IronPetCore

/// GTD's weekly review digest and the goal alignment score.
final class WeeklyReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_788_000) // Friday 2026-11-27, 15:00 UTC
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func task(_ id: String, _ status: TaskStatus = .backlog, project: String? = nil, waitingOn: String? = nil, askedAt: Date? = nil,
                      deferUntil: Date? = nil, closed: Date? = nil) -> TaskItem {
        TaskItem(id: id, title: "Task \(id)", notes: "", status: status, source: .user, links: [], created: now.addingTimeInterval(-30 * 86_400),
                 updated: now.addingTimeInterval(-86_400), closed: closed, waitingOn: waitingOn, deferUntil: deferUntil, project: project, askedAt: askedAt)
    }

    private func project(_ id: String, goal: String? = nil, reviewDays: Int? = nil) -> TaskProject {
        TaskProject(id: id, title: "Project \(id)", goal: goal, reviewDays: reviewDays, created: now.addingTimeInterval(-30 * 86_400),
                    updated: now.addingTimeInterval(-30 * 86_400))
    }

    private func goal(_ id: String, _ status: TaskGoal.Status = .active) -> TaskGoal {
        TaskGoal(id: id, title: "Goal \(id)", why: "", area: nil, status: status, due: nil, created: now, updated: now)
    }

    func testTheReviewFollowsGTDsOrder() {
        let input = BriefInput(
            now: now, calendar: calendar,
            tasks: [task("step", project: "moving"), task("held", waitingOn: "Ana", askedAt: now.addingTimeInterval(-10 * 86_400)),
                    task("later", deferUntil: now.addingTimeInterval(3 * 86_400)), task("cello", .someday),
                    task("shipped", .done, project: "moving", closed: now.addingTimeInterval(-86_400)),
                    task("chore", .done, closed: now.addingTimeInterval(-2 * 86_400))],
            suggestions: [TaskSuggestion(id: "s", title: "Reply to Sam", origin: .taskScan, created: now)],
            projects: [project("moving", goal: "home", reviewDays: 7), project("site")],
            goals: [goal("home")],
            keyResults: [TaskKeyResult(id: "k", goal: "home", metric: "Boxes packed", start: 0, target: 40, current: 10, unit: nil, due: nil,
                                       source: nil, updated: now)])
        let review = BriefBuilder.build(.review, input)
        XCTAssertEqual(review.kind, .review)
        XCTAssertEqual(review.sections.map(\.id), ["inbox", "stalled", "follow-ups", "projects", "returning", "someday", "goals", "alignment"])
        XCTAssertEqual(review.sections.first { $0.id == "stalled" }?.items.map(\.title), ["Project site"], "moving has a next action")
        XCTAssertEqual(review.sections.first { $0.id == "goals" }?.items.first?.subtitle, "25%")
        XCTAssertEqual(review.lines, ["Inbox: 1 to clarify", "1 project needs a next action", "1 follow-up due", "Goal alignment: 50%"],
                       "the score always makes the bubble")
    }

    func testAnEmptyWeekHasNothingToReview() {
        XCTAssertTrue(BriefBuilder.build(.review, BriefInput(now: now, calendar: calendar)).sections.isEmpty)
    }

    func testAlignmentCountsClosedTasksWhoseProjectServesAnActiveGoal() {
        let week = DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
        let closed = [task("a", .done, project: "p", closed: now.addingTimeInterval(-3600)),
                      task("b", .done, closed: now.addingTimeInterval(-3600)),
                      task("c", .done, project: "q", closed: now.addingTimeInterval(-3600)),
                      task("old", .done, project: "p", closed: now.addingTimeInterval(-20 * 86_400))]
        let projects = [project("p", goal: "g"), project("q", goal: "done")]
        let score = GoalAlignment.score(BriefInput(now: now, tasks: closed, projects: projects, goals: [goal("g"), goal("done", .achieved)]), in: week)
        XCTAssertEqual(score, GoalAlignment.Score(aligned: 1, total: 3))
        XCTAssertEqual(score?.title, "Goal alignment: 33%")
        XCTAssertNil(GoalAlignment.score(BriefInput(now: now, tasks: closed, projects: projects), in: week), "no goal to align to")
        XCTAssertNil(GoalAlignment.score(BriefInput(now: now, projects: projects, goals: [goal("g")]), in: week), "nothing closed")
    }

    func testTheBriefShowsAlignmentOnlyOnceThereIsAGoal() {
        let shipped = task("shipped", .done, project: "p", closed: now.addingTimeInterval(-3600))
        let without = BriefBuilder.build(.brief, BriefInput(now: now, calendar: calendar, tasks: [shipped, task("ask", .needsYou)], projects: [project("p")]))
        XCTAssertFalse(without.sections.contains { $0.id == "alignment" })
        let with = BriefBuilder.build(.brief, BriefInput(now: now, calendar: calendar, tasks: [shipped, task("ask", .needsYou)],
                                                         projects: [project("p", goal: "g")],
                                                         goals: [goal("g")]))
        XCTAssertEqual(with.sections.first { $0.id == "alignment" }?.items.first?.title, "Goal alignment: 100%")
    }

    func testTheWeeklyReviewIsABuiltInOnFridayAfternoonThatStartsOff() throws {
        let review = try XCTUnwrap(AutomationDefaults.builtIns.first { $0.id == AutomationDefaults.weeklyReviewID })
        XCTAssertFalse(review.enabled)
        XCTAssertEqual(review.trigger.times, ["15:00"])
        XCTAssertEqual(review.trigger.weekdays, ["fri"])
        XCTAssertEqual(review.action.digest, "review")
    }

    func testAQuietBriefStaysEmptyEvenWithAGoal() {
        let shipped = task("shipped", .done, project: "p", closed: now.addingTimeInterval(-3600))
        let brief = BriefBuilder.build(.brief, BriefInput(now: now, calendar: calendar, tasks: [shipped], projects: [project("p", goal: "g")],
                                                          goals: [goal("g")]))
        XCTAssertTrue(brief.isEmpty, "alignment alone is not news")
    }

    func testAReviewWithOnlyAGoalStillHasABubbleLine() {
        let review = BriefBuilder.build(.review, BriefInput(now: now, calendar: calendar, goals: [goal("g")]))
        XCTAssertFalse(review.isEmpty)
        XCTAssertEqual(review.lines, ["1 active goal"])
    }
}
