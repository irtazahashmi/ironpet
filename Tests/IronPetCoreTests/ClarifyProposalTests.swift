import XCTest
@testable import IronPetCore
import IronPetKit

/// The task scan's clarify proposal: parsed from the agent, kept with the suggestion, applied when it is added.
@MainActor
final class ClarifyProposalTests: XCTestCase {
    private var store: TaskStore!

    override func setUp() async throws {
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, keepDoneDays: { 30 })
    }

    private func file(_ clarify: TaskSuggestion.Clarify?, title: String = "Call the dentist") throws -> TaskSuggestion {
        var draft = TaskSuggestion.Draft(key: "scan", title: title)
        draft.clarify = clarify
        return try XCTUnwrap(store.suggest(scan: [draft]).first)
    }

    func testTheScanAnswerCarriesTheProposal() throws {
        let answer = #"{"new":[{"title":"Call the dentist","context":"Phone","area":"Health","two_minute":true,"someday":false}],"updates":[]}"#
        let proposals = try TaskScanner.parse(answer, knownTasks: []).get()
        XCTAssertEqual(proposals.new.first?.clarify, TaskSuggestion.Clarify(context: .phone, area: "Health", twoMinute: true))
    }

    func testAnUnknownContextIsDroppedButTheTaskIsStillFiled() throws {
        let answer = #"{"new":[{"title":"Fix the printer","context":"office","area":"Home"}],"updates":[]}"#
        let proposal = try XCTUnwrap(try TaskScanner.parse(answer, knownTasks: []).get().new.first)
        XCTAssertEqual(proposal.title, "Fix the printer")
        XCTAssertEqual(proposal.clarify, TaskSuggestion.Clarify(area: "Home"))
    }

    func testAnEntryWithoutClarifyFieldsHasNoProposal() throws {
        let proposal = try XCTUnwrap(try TaskScanner.parse(#"{"new":[{"title":"A"}],"updates":[]}"#, knownTasks: []).get().new.first)
        XCTAssertNil(proposal.clarify)
    }

    func testTheProposalSurvivesAReload() throws {
        let clarify = TaskSuggestion.Clarify(context: .errands, area: "House", twoMinute: false, someday: true)
        _ = try file(clarify)
        store.reload()
        XCTAssertEqual(store.suggestions.first?.clarify, clarify)
        XCTAssertEqual(clarify.summary, "Errands · House · Someday")
    }

    func testAddingAppliesTheProposalInOneStep() throws {
        let suggestion = try file(TaskSuggestion.Clarify(context: .phone, area: "Health", twoMinute: true))
        let task = try store.accept(suggestion.id)
        XCTAssertEqual(task.labels, ["context": "phone", "area": "Health"])
        XCTAssertEqual(task.status, .backlog)
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testASomedayProposalFilesTheTaskAsSomedayUnlessTheReviewerSaysOtherwise() throws {
        let musing = try file(TaskSuggestion.Clarify(someday: true), title: "Learn the cello")
        XCTAssertEqual(try store.accept(musing.id).status, .someday)
        let other = try file(TaskSuggestion.Clarify(someday: true), title: "Learn Italian")
        XCTAssertEqual(try store.accept(other.id, overrides: .init(status: "in_progress")).status, .inProgress)
    }

    func testASuggestionWithoutAProposalAddsToTheBacklogAsBefore() throws {
        let plain = try file(nil)
        let task = try store.accept(plain.id)
        XCTAssertEqual(task.status, .backlog)
        XCTAssertTrue(task.labels.isEmpty)
    }

    func testAgentsSeeTheProposal() throws {
        let suggestion = try file(TaskSuggestion.Clarify(context: .mac, twoMinute: true))
        let clarify = try XCTUnwrap(TaskJSON.json(suggestion)["clarify"] as? [String: Any])
        XCTAssertEqual(clarify["context"] as? String, "mac")
        XCTAssertEqual(clarify["two_minute"] as? Bool, true)
        XCTAssertNil(clarify["area"])
    }

    func testTheAreaIsCleanedLikeTheRestOfTheScanText() throws {
        let entry: [String: Any] = ["title": "A", "area": "Sa\u{202E}les\u{0007}"]
        XCTAssertEqual(TaskScanner.clarify(entry)?.area, "Sales")
    }

    func testWorkSomeoneElseHoldsIsNeverProposedAsSomeday() throws {
        let entry: [String: Any] = ["title": "A", "waiting_on": "Ana", "someday": true, "context": "calls"]
        XCTAssertEqual(TaskScanner.clarify(entry), TaskSuggestion.Clarify(context: .calls))
    }

    func testThePhoneReceivesTheProposalWithTheSameWording() throws {
        let suggestion = try file(TaskSuggestion.Clarify(context: .phone, area: "Health", twoMinute: true))
        let remote = RemoteSuggestion(suggestion)
        XCTAssertEqual(remote.clarify, RemoteSuggestionClarify(context: "phone", area: "Health", twoMinute: true))
        XCTAssertEqual(remote.clarify?.summary, suggestion.clarify?.summary)
        XCTAssertEqual(remote.clarify?.summary, "Phone · Health · 2 min")
        let decoded = try JSONDecoder().decode(RemoteSuggestionClarify.self, from: Data(#"{"context":"mac"}"#.utf8))
        XCTAssertEqual(decoded, RemoteSuggestionClarify(context: "mac"), "missing flags read as false")
    }
}
