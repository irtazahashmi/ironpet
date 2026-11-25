import XCTest
import IronPetKit
@testable import IronPetRemote

/// A burst of events reads each screen once, and the Tasks list asks for done tasks only when its Done section is open.
@MainActor
final class SyncTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    private func events(_ client: IronPetClient) -> SharedEventSource {
        SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 700_000_000) }

    func testADebouncedRunRunsOnceForABurstOfTheSameKey() async {
        let debouncer = EventDebouncer()
        var runs = 0
        for _ in 0..<10 { debouncer.run("pet") { runs += 1 } }
        await settle()
        XCTAssertEqual(runs, 1, "ten events under one key read once")
        debouncer.run("pet") { runs += 1 }
        debouncer.cancelAll()
        await settle()
        XCTAssertEqual(runs, 1, "a cancelled run never happens")
    }

    func testABurstOfBubbleEventsReadTheBubblesOnce() async {
        let c = client()
        let model = PetModel(client: c, events: events(c), cache: AssetCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sync-assets-\(UUID().uuidString)")), onUnauthorized: {})
        model.start()
        await poll { model.loaded }
        await settle()
        let before = server.count("GET /v1/bubbles")
        for _ in 0..<10 { _ = server.publish(RemoteEvent.bubbleShown) }
        await settle()
        XCTAssertEqual(server.count("GET /v1/bubbles") - before, 1, "a burst of bubble events reads the bubbles once")
        model.stop()
    }

    func testTheTasksListLeavesDoneTasksOutUntilTheDoneSectionOpens() async {
        let defaults = UserDefaults(suiteName: "sync-tasks-\(UUID().uuidString)")!
        let c = client()
        let model = TasksModel(client: c, events: events(c), defaults: defaults, onUnauthorized: {})
        model.start()
        await poll { model.loaded }
        let first = server.requests.last { $0.path == "/v1/tasks" }
        XCTAssertNotNil(first)
        XCTAssertFalse(first?.query.contains("include_done") ?? true, "a collapsed list asks for open tasks only")
        XCTAssertFalse(model.showsDone)
        XCTAssertTrue(model.done.isEmpty)

        await model.setShowsDone(true)
        let opened = server.requests.last { $0.path == "/v1/tasks" }
        XCTAssertTrue(opened?.query.contains("include_done=1") ?? false, "opening the section asks for the done tasks")
        XCTAssertTrue(model.showsDone)
        model.stop()
    }
}
