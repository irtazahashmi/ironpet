import XCTest
@testable import IronPet
@testable import IronPetCore

/// Drives the inbox only through `IronPetAPI`, over an in-memory database.
@MainActor
final class TasksAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var api: IronPetAPI!

    override func setUp() async throws {
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        api = APITestSupport.makeAPI(events: events)
    }

    private func add(_ key: String, _ title: String, due: String? = nil) {
        api.tasks.suggest(SuggestTaskRequest(draft: .init(key: key, title: title, due: due), kind: .pr, sourceRef: "pr:\(key)"))
    }

    func testAddedItemsAreListedOldestFirstWithTheirOrigin() throws {
        add("a", "Review the PR")
        add("b", "Send the notes", due: "2026-11-20")
        let items = api.tasks.suggestions
        XCTAssertEqual(items.map(\.title), ["Review the PR", "Send the notes"])
        XCTAssertEqual(items[1].due, "2026-11-20")
        XCTAssertNotNil(items[0].created)
    }

    func testAnItemWithTheSameKeyOrTitleIsAddedOnce() {
        add("a", "Review the PR")
        add("b", "Review the PR")
        XCTAssertEqual(api.tasks.suggestions.count, 1, "a title that is already there is not added")
        add("a", "Another title")
        XCTAssertEqual(api.tasks.suggestions.map(\.title), ["Another title"], "the same key updates the item")
    }

    func testDoneTakesTheItemOffTheListAndCreatesNothingElse() throws {
        add("a", "Review the PR")
        let id = try XCTUnwrap(api.tasks.suggestions.first?.id)
        try api.tasks.done(id)
        XCTAssertTrue(api.tasks.suggestions.isEmpty)
        XCTAssertThrowsError(try api.tasks.done(id)) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testRemoveTakesAWrongItemOffTheList() throws {
        add("a", "Wrong item")
        let id = try XCTUnwrap(api.tasks.suggestions.first?.id)
        try api.tasks.remove(RemoveSuggestionRequest(id: id, note: "duplicate"))
        XCTAssertTrue(api.tasks.suggestions.isEmpty)
        XCTAssertThrowsError(try api.tasks.remove(RemoveSuggestionRequest(id: id))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testAnItemDoneOnceDoesNotComeBackWhenTheSameKeyIsSuggestedAgain() throws {
        add("a", "Review the PR")
        try api.tasks.done(try XCTUnwrap(api.tasks.suggestions.first?.id))
        add("a", "Review the PR")
        XCTAssertTrue(api.tasks.suggestions.isEmpty, "a handled item stays handled")
    }

    func testChangesArriveOnTheEventBus() throws {
        add("a", "Review the PR")
        try api.tasks.done(try XCTUnwrap(api.tasks.suggestions.first?.id))
        XCTAssertEqual(seen.map(\.kind), [.suggestionsChanged, .suggestionsChanged])
        XCTAssertEqual(seen.map(\.seq), [1, 2])
    }

    func testRequestsRoundTripAsJSON() throws {
        let request = SuggestTaskRequest(draft: .init(key: "k", title: "Round trip", due: "2026-11-20"), kind: .email, sourceRef: "mail:1")
        XCTAssertEqual(try JSONDecoder().decode(SuggestTaskRequest.self, from: JSONEncoder().encode(request)), request)
        let removal = RemoveSuggestionRequest(id: "x", note: "n")
        XCTAssertEqual(try JSONDecoder().decode(RemoveSuggestionRequest.self, from: JSONEncoder().encode(removal)), removal)
    }

    func testTheJSONAdapterGoesThroughTheAPI() throws {
        let origin: [String: Any] = ["kind": "agent", "ref": "session 3", "reason": "CI failed"]
        guard case .success(let added) = TaskJSON.call(api.tasks, "add", ["id": "ci", "title": "Look at CI", "origin": origin], by: "agent:mcp") else {
            return XCTFail("add failed")
        }
        XCTAssertEqual((added as? [String: Any])?["added"] as? Bool, true)
        let id = try XCTUnwrap(api.tasks.suggestions.first?.id)
        guard case .success(let listed) = TaskJSON.call(api.tasks, "list", [:], by: "agent:mcp") else { return XCTFail("list failed") }
        XCTAssertEqual(((listed as? [String: Any])?["items"] as? [[String: Any]])?.first?["id"] as? String, id)
        guard case .success = TaskJSON.call(api.tasks, "done", ["id": id], by: "agent:mcp") else { return XCTFail("done failed") }
        guard case .failure(let error) = TaskJSON.call(api.tasks, "done", ["id": id], by: "agent:mcp") else { return XCTFail("done twice") }
        XCTAssertTrue(error.message.contains("no inbox item"), error.message)
        guard case .failure(let unknown) = TaskJSON.call(api.tasks, "create", ["title": "x"], by: "agent:mcp") else { return XCTFail("create is gone") }
        XCTAssertTrue(unknown.message.contains("unknown operation"), unknown.message)
    }
}
