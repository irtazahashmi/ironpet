import XCTest
import IronPetKit
@testable import IronPetRemote

/// Suggestions that change an existing task, as the phone shows and answers them.
@MainActor
final class UpdateSuggestionPhoneTests: XCTestCase {
    var server: MockIronPetServer!
    private let update = RemoteSuggestion(
        id: "u-1", title: "Reply from legal", origin: "task-scan", originDetail: "Task scan",
        update: RemoteSuggestionUpdate(taskID: "t-waiting", taskTitle: "Reply from legal", note: "Legal answered on Monday.", status: "done"))

    override func setUpWithError() throws {
        server = MockIronPetServer(suggestions: [update])
        try server.start()
    }

    override func tearDown() async throws { server.stop() }

    private func makeModel() -> TasksModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))
        return TasksModel(client: client, events: events, onUnauthorized: {})
    }

    func testTheUpdateNamesTheTaskAndTheChange() async throws {
        let model = makeModel()
        await model.reload()
        let suggestion = try XCTUnwrap(model.suggestions.first)
        XCTAssertEqual(suggestion.update?.headline, "Update: Reply from legal")
        XCTAssertEqual(suggestion.update?.summary, "Mark done. Note: Legal answered on Monday.")
    }

    func testAcceptAppliesTheChangeToTheTask() async throws {
        let model = makeModel()
        await model.reload()
        await model.add(model.suggestions[0])
        XCTAssertEqual(server.count("POST /v1/suggestions/u-1/accept"), 1)
        XCTAssertEqual(model.suggestions, [])
        XCTAssertEqual(server.tasks.first { $0.id == "t-waiting" }?.status, .done)
        XCTAssertEqual(model.tasks.filter { $0.title == "Reply from legal" }.count, 1, "no second task was made")
    }

    func testSkipLeavesTheTaskAsItIs() async throws {
        let model = makeModel()
        await model.reload()
        await model.skip(model.suggestions[0])
        XCTAssertEqual(server.count("POST /v1/suggestions/u-1/reject"), 1)
        XCTAssertEqual(model.suggestions, [])
        XCTAssertEqual(server.tasks.first { $0.id == "t-waiting" }?.status, .needsYou)
    }
}
