import XCTest
@testable import IronPetCore

/// The similarity test behind near-duplicate notes. The pairs here are the ones the threshold in `NearDuplicate` was chosen from.
final class NearDuplicateTests: XCTestCase {
    static let bloated = "Finds Orca bloated with features he does not need and wants a smaller board for many agents on many machines."
    static let restatements = [
        "Finds Orca bloated with features he considers unnecessary and wants a leaner board that shows an overview first and details only on demand.",
        "Finds Orca too feature-heavy and wants a lean central board to watch many agents across machines, with details opened only on demand.",
        "Finds Orca bloated with features that are unnecessary for running agents and tracking work.",
    ]
    static let branches = "Orca prefixes agent worktree branches with the user's name, so a branch requested as fix/<name> is created as amirilovic/fix/<name>."
    static let jiraA = "Wants Jira tickets closed once their PR has merged; tickets with an open PR or waiting on a release stay In Progress."
    static let jiraB = "Wants Jira tickets in In Progress closed once their PR has merged. Tickets whose PR is still open, or that wait on a release, stay In Progress."

    func testRewordingsOfOneFactAreNear() {
        for text in Self.restatements { XCTAssertTrue(NearDuplicate.areNear(Self.bloated, text), text) }
        XCTAssertTrue(NearDuplicate.areNear(Self.jiraA, Self.jiraB))
    }

    func testDifferentFactsAboutOneSubjectAreNot() {
        let pairs = [
            (Self.bloated, Self.branches),
            (Self.branches, "Orca names each worktree after its branch and deletes the worktree once the pull request merges."),
            (Self.bloated, "Runs Orca on his laptop to keep several agents working in parallel worktrees."),
            (Self.jiraA, "Keeps Jira estimates in story points and sets them before a ticket moves to In Progress."),
        ]
        for (a, b) in pairs { XCTAssertFalse(NearDuplicate.areNear(a, b), "\(a) / \(b)") }
    }

    func testShortNotesThatDifferInOneWordAreNotNear() {
        XCTAssertFalse(NearDuplicate.areNear("Uses npm", "Uses pnpm"))
        XCTAssertFalse(NearDuplicate.areNear("Prefers tabs over spaces.", "Prefers spaces over tabs in Python."))
    }

    func testGroupsChainRewordingsAndKeepDifferentFactsApart() {
        let texts = [Self.bloated] + Self.restatements + [Self.branches, Self.jiraA, Self.jiraB]
        XCTAssertEqual(NearDuplicate.groups(texts), [[0, 1, 2, 3], [5, 6]])
    }
}
