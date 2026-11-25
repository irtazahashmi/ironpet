import XCTest
@testable import IronPetCore
import IronPetKit

/// How an update suggestion is stored, sent to the phone and shown by the API.
@MainActor
final class UpdateSuggestionModelTests: XCTestCase {
    private var store: TaskStore!

    override func setUp() async throws {
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, keepDoneDays: { 30 })
    }

    private func fileUpdate(_ target: TaskItem, note: String? = "Sent on Tuesday.", done: Bool = true) throws -> TaskSuggestion {
        let filed = store.suggest(scanUpdates: [(TaskSuggestion.Update(target: target.id, targetTitle: "stale", note: note, markDone: done), nil)])
        return try XCTUnwrap(filed.first)
    }

    func testAnUpdateSurvivesAReloadWithTheTargetsCurrentTitle() throws {
        let target = try store.create(title: "Send Tom the deck", source: .user, by: "test")
        let filed = try fileUpdate(target)
        XCTAssertEqual(filed.update?.targetTitle, "Send Tom the deck", "the title comes from the task, not from the agent")
        store.reload()
        let stored = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(stored.update, filed.update)
        XCTAssertEqual(stored.origin, .taskScan)
        XCTAssertEqual(stored.headline, "Update: Send Tom the deck")
    }

    func testAnUpdateForATaskThatIsDoneOrMissingOrChangesNothingIsNotFiled() throws {
        let done = try store.create(title: "Old job", status: .done, source: .user, by: "test")
        let open = try store.create(title: "Open job", source: .user, by: "test")
        let filed = store.suggest(scanUpdates: [
            (TaskSuggestion.Update(target: done.id, targetTitle: "", markDone: true), nil),
            (TaskSuggestion.Update(target: "missing", targetTitle: "", markDone: true), nil),
            (TaskSuggestion.Update(target: open.id, targetTitle: ""), nil),
        ])
        XCTAssertEqual(filed, [])
    }

    func testTheRemoteFormCarriesTheOriginAndTheChange() throws {
        let target = try store.create(title: "Send Tom the deck", source: .user, by: "test")
        let remote = RemoteSuggestion(try fileUpdate(target))
        XCTAssertEqual(remote.origin, "task-scan")
        XCTAssertEqual(remote.update?.taskID, target.id)
        XCTAssertEqual(remote.update?.headline, "Update: Send Tom the deck")
        XCTAssertEqual(remote.update?.summary, "Mark done. Note: Sent on Tuesday.")
    }

    func testANewTaskSuggestionHasNoUpdateInTheRemoteForm() {
        let filed = store.suggest(scan: [TaskSuggestion.Draft(key: "scan", title: "Book the room")])
        let remote = RemoteSuggestion(filed[0])
        XCTAssertNil(remote.update)
        XCTAssertEqual(remote.origin, "task-scan")
    }

    func testTheToolJSONShowsTheTargetAndTheChange() throws {
        let target = try store.create(title: "Send Tom the deck", source: .user, by: "test")
        let json = TaskJSON.json(try fileUpdate(target))
        XCTAssertEqual(json["origin"] as? String, "task-scan")
        let change = try XCTUnwrap(json["update"] as? [String: Any])
        XCTAssertEqual(change["task_id"] as? String, target.id)
        XCTAssertEqual(change["status"] as? String, "done")
    }

    func testAcceptKeepsTheReviewersNoteInTheTasksHistory() throws {
        let target = try store.create(title: "Send Tom the deck", source: .user, by: "test")
        let filed = try fileUpdate(target)
        try store.accept(filed.id, note: "Confirmed in the chat", by: "agent:mcp")
        XCTAssertTrue(store.history(target.id).contains { $0.kind == .note && $0.detail == "Confirmed in the chat" })
    }
}
