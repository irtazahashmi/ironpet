import XCTest
import IronPetKit
@testable import IronPetRemote

/// Quick filters on the phone: the chips the Mac saved, the local filtering, Remove, and the prompts Add and Edit send to the chat.
@MainActor
final class QuickFilterPhoneTests: XCTestCase {
    var server: MockIronPetServer!
    private let epic = QuickFilter(id: "epic", name: "Epic", query: .object(["label": .object(["project": .string("epic")])]), order: 0)
    private let mine = QuickFilter(id: "mine", name: "Needs me", query: .object(["status": .string("needs_you")]), order: 1)

    override func setUpWithError() throws {
        server = MockIronPetServer(tasks: [
            RemoteTask(id: "t-epic", title: "Plan the epic", status: .inProgress, labels: ["project": "epic"]),
            RemoteTask(id: "t-mine", title: "Review the contract", status: .needsYou),
            RemoteTask(id: "t-done", title: "Ship the epic beta", status: .done, closed: Date(), labels: ["project": "epic"]),
        ], suggestions: [])
        server.taskFilters = [epic, mine]
        try server.start()
    }

    override func tearDown() { server.stop() }

    private var client: IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    private func model(defaults: UserDefaults? = nil) -> TasksModel {
        TasksModel(client: client, events: SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))),
                   defaults: defaults ?? scratchDefaults(), onUnauthorized: {})
    }

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ironpet-tasks-filter-\(UUID().uuidString)")!
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // S4
    func testTheChipsAreTheMacsFiltersAndPickingOneFiltersTheListLocally() async {
        let model = model()
        await model.reload()
        XCTAssertEqual(model.filters.map(\.name), ["Epic", "Needs me"])
        XCTAssertEqual(Set((model.needsYou + model.inProgress + model.backlog + model.waiting + model.done).map(\.id)), ["t-epic", "t-mine", "t-done"], "All shows everything")

        model.selectedFilterID = "epic"
        XCTAssertEqual(Set(model.inProgress.map(\.id)), ["t-epic"])
        XCTAssertEqual(model.needsYou, [])
        XCTAssertEqual(model.done.map(\.id), ["t-done"], "the filter applies to the Done group too")
        XCTAssertEqual(Set(model.boardColumns.values.flatMap { $0 }.map(\.id)), ["t-epic", "t-done"], "and to the board")

        model.selectedFilterID = "mine"
        XCTAssertEqual(model.needsYou.map(\.id), ["t-mine"])
        XCTAssertEqual(model.inProgress, [])
        let requests = server.requests.map(\.line).filter { $0.contains("task-filters") }
        XCTAssertEqual(requests, ["GET /v1/task-filters"], "the filtering did not ask the Mac again")
    }

    // S4
    func testRemovingAFilterCallsTheMacAndFallsBackToAll() async throws {
        let model = model()
        await model.reload()
        model.selectedFilterID = "epic"
        let removed = await model.removeFilter(epic)
        XCTAssertTrue(removed)
        XCTAssertEqual(server.requests.map(\.line).filter { $0.hasPrefix("DELETE") }, ["DELETE /v1/task-filters/epic"])
        XCTAssertEqual(model.filters.map(\.id), ["mine"])
        XCTAssertNil(model.selectedFilterID)
        XCTAssertEqual(Set(model.inProgress.map(\.id)), ["t-epic"], "the list shows every task again")
    }

    func testASettingsChangedEventReloadsTheChips() async {
        let model = model()
        model.start()
        await poll { model.loaded && model.filters.count == 2 }
        server.taskFilters = [mine]
        server.publish(RemoteEvent.settingsChanged)
        await poll { model.filters.count == 1 }
        XCTAssertEqual(model.filters.map(\.id), ["mine"])
        model.stop()
    }

    func testAnOlderMacHidesTheChips() async {
        server.taskFiltersSupported = false
        let model = model()
        model.selectedFilterID = "epic"
        await model.reload()
        XCTAssertFalse(model.filtersSupported)
        XCTAssertEqual(model.filters, [])
        XCTAssertNil(model.selectedFilterID)
        XCTAssertNil(model.errorMessage, "a 404 on the filter route is not an error to show")
        XCTAssertEqual(Set(model.inProgress.map(\.id)), ["t-epic"])
    }

    func testAFilterThisBuildCannotReadIsNotShown() async {
        server.taskFilters = [epic, QuickFilter(id: "future", name: "Future", query: .object(["somethingNew": .bool(true)]), order: 2)]
        let model = model()
        await model.reload()
        XCTAssertEqual(model.filters.map(\.id), ["epic"])
    }

    // S5
    func testAddAndEditSendThePromptToTheMainChat() async throws {
        let client = self.client
        let chat = ChatModel(client: client, events: SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))),
                             onUnauthorized: {})
        chat.start()
        await poll { chat.loaded && chat.snapshot != nil }
        chat.draft = "half-typed note"

        await chat.sendPrompt(QuickFilterRequest.add.prompt("epic tasks not done"))
        await chat.sendPrompt(QuickFilterRequest.edit(epic).prompt("also hide blocked ones"))
        let sent = server.requests.filter { $0.line == "POST /v1/chat/current/messages" }.compactMap { $0.json["text"] as? String }
        XCTAssertEqual(sent, [
            "Create a task quick filter: epic tasks not done",
            #"Change the task quick filter "Epic" (id epic, current query {"label":{"project":"epic"}}): also hide blocked ones"#,
        ])
        XCTAssertEqual(chat.draft, "half-typed note", "the composer is left alone")
        chat.stop()
    }

    // S3
    func testThePickedFilterIsReadBackByAFreshModel() async {
        let defaults = scratchDefaults()
        let first = model(defaults: defaults)
        await first.reload()
        first.selectedFilterID = "epic"
        let relaunched = model(defaults: defaults)
        XCTAssertEqual(relaunched.selectedFilterID, "epic")
        await relaunched.reload()
        XCTAssertEqual(relaunched.selectedFilterID, "epic")
        XCTAssertEqual(Set(relaunched.inProgress.map(\.id)), ["t-epic"], "the list is filtered by it")
    }

    // S4
    func testAStoredFilterTheMacNoLongerHasShowsAllAndClearsTheStoredValue() async {
        let defaults = scratchDefaults()
        QuickFilterSelection.save("deleted", defaults)
        let model = model(defaults: defaults)
        await model.reload()
        XCTAssertNil(model.selectedFilterID)
        XCTAssertNil(QuickFilterSelection.load(defaults))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(Set((model.needsYou + model.inProgress + model.backlog + model.waiting + model.done).map(\.id)), ["t-epic", "t-mine", "t-done"])
    }
}
