import IronPetKit
import Security
import XCTest
@testable import IronPetRemote

private func waitUntil(_ timeout: Double = 30, _ condition: @escaping @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// S4: the token's Keychain item.
final class KeychainTests: XCTestCase {
    func testAddQueryKeepsTheTokenOnThisDeviceOnly() {
        let query = KeychainCredentialStore.addQuery(service: "s", account: "a", data: Data([1]))
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    func testEveryQueryExcludesSynchronizedItems() {
        XCTAssertEqual(KeychainCredentialStore.baseQuery(service: "s", account: "a")[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testRoundTrip() throws {
        let store = KeychainCredentialStore(service: "dev.ironpet.remote.tests.\(UUID().uuidString)")
        defer { store.delete() }
        XCTAssertNil(store.load())
        let device = PairedDevice(endpoint: ServerEndpoint(baseURL: URL(string: "https://192.168.1.2:47380")!, pin: String(repeating: "a", count: 64)),
                                  token: "ipt_x", deviceID: "d1")
        try store.save(device)
        XCTAssertEqual(store.load(), device)
        store.delete()
        XCTAssertNil(store.load())
    }
}

@MainActor
final class PairingModelTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() async throws { server.stop() }

    func model(onPaired: @escaping (PairedDevice) -> Void = { _ in }) -> PairingModel {
        let model = PairingModel(deviceName: "Test phone", onPaired: onPaired)
        model.pollInterval = .milliseconds(10)
        return model
    }

    func testPairsWhenTheMacAllows() async {
        var paired: PairedDevice?
        let model = model { paired = $0 }
        model.submit(server.pairingLink)
        await waitUntil { paired != nil }
        XCTAssertEqual(paired?.token, server.token)
        XCTAssertEqual(model.state, .idle)
    }

    /// S2
    func testDenialIsShownAndPairingStays() async {
        server.outcome = .deny
        var paired: PairedDevice?
        let model = model { paired = $0 }
        model.submit(server.pairingLink)
        await waitUntil { model.state == .denied }
        XCTAssertEqual(model.state, .denied)
        XCTAssertNil(paired)
    }

    func testShowsWaitingWhileThePollIsPending() async {
        server.pendingPolls = 1000
        let model = model()
        model.submit(server.pairingLink)
        await waitUntil { model.state == .waiting }
        XCTAssertEqual(model.state, .waiting)
        model.cancel()
        XCTAssertEqual(model.state, .idle)
    }

    func testRejectsTextThatIsNotALink() {
        let model = model()
        model.submit("hello")
        guard case .failed = model.state else { return XCTFail("\(model.state)") }
    }
}

@MainActor
final class TasksModelTests: XCTestCase {
    var server: MockIronPetServer!
    var unauthorized = 0

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() async throws { server.stop() }

    func makeModel() -> TasksModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))
        return TasksModel(client: client, events: events, onUnauthorized: { [unowned self] in unauthorized += 1 })
    }

    func testSectionsFollowTheMacsList() async {
        let model = makeModel()
        await model.reload()
        await model.setShowsDone(true)
        XCTAssertEqual(model.suggestions.map(\.id), ["s-1", "s-2"])
        XCTAssertEqual(model.needsYou.map(\.id), ["t-needs"])
        XCTAssertEqual(model.inProgress.map(\.id), ["t-progress"])
        XCTAssertEqual(model.backlog.map(\.id), ["t-backlog"])
        XCTAssertEqual(model.waiting.map(\.id), ["t-waiting"], "a task waiting on someone leaves Needs you")
        XCTAssertEqual(model.done.map(\.id), ["t-done"])
    }

    // MARK: Board

    private func boardModel() async -> TasksModel {
        var recent = server.tasks.first { $0.id == "t-done" }!
        recent.closed = Date()
        server.tasks = server.tasks.map { $0.id == "t-done" ? recent : $0 }
        let model = makeModel()
        await model.reload()
        await model.setShowsDone(true)
        return model
    }

    func testBoardColumnsHoldTheListGroupsAndOnlyRecentDoneTasks() async {
        let model = await boardModel()
        let columns = model.boardColumns
        XCTAssertEqual(columns[.needsYou]?.map(\.id), ["t-needs"])
        XCTAssertEqual(columns[.inProgress]?.map(\.id), ["t-progress"])
        XCTAssertEqual(columns[.backlog]?.map(\.id), ["t-backlog"])
        XCTAssertEqual(columns[.waiting]?.map(\.id), ["t-waiting"])
        XCTAssertEqual(columns[.done]?.map(\.id), ["t-done"])
        let old = RemoteTask(id: "old", title: "Old", status: .done, closed: Date().addingTimeInterval(-8 * 86_400))
        XCTAssertNil(TasksModel.boardColumns([old])[.done], "a task closed 8 days ago is past the 7 day window")
    }

    func testDroppingOnAnotherColumnSendsTheStatus() async {
        let model = await boardModel()
        let outcome = await model.drop("t-progress", on: .needsYou)
        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(server.requests.filter { $0.line == "PATCH /v1/tasks/t-progress" }.count, 1)
        XCTAssertEqual(server.requests.last { $0.method == "PATCH" }?.json["status"] as? String, "needs_you")
        XCTAssertEqual(server.tasks.first { $0.id == "t-progress" }?.status, .needsYou)
        XCTAssertEqual(model.boardColumns[.needsYou]?.map(\.id).sorted(), ["t-needs", "t-progress"])
        let again = await model.drop("t-progress", on: .needsYou)
        XCTAssertEqual(again, .unchanged)
    }

    func testDroppingOnWaitingAsksForANameAndHoldSendsIt() async {
        let model = await boardModel()
        let outcome = await model.drop("t-backlog", on: .waiting)
        XCTAssertEqual(outcome, .needsName)
        XCTAssertTrue(server.requests.filter { $0.method == "PATCH" }.isEmpty, "nothing is sent before a name is given")
        let blank = await model.hold("t-backlog", name: "  ")
        XCTAssertFalse(blank)
        let held = await model.hold("t-backlog", name: "Ana")
        XCTAssertTrue(held)
        XCTAssertEqual(server.requests.last { $0.method == "PATCH" }?.json["waiting_on"] as? String, "Ana")
        XCTAssertNil(server.requests.last { $0.method == "PATCH" }?.json["status"])
        XCTAssertEqual(model.boardColumns[.waiting]?.map(\.id).sorted(), ["t-backlog", "t-waiting"])
    }

    func testDroppingAWaitingTaskElsewhereClearsWaitingOnInTheSameRequest() async {
        let model = await boardModel()
        let outcome = await model.drop("t-waiting", on: .inProgress)
        XCTAssertEqual(outcome, .moved)
        let patches = server.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].json["waiting_on"] as? String, "")
        XCTAssertEqual(patches[0].json["status"] as? String, "in_progress")
        XCTAssertNil(server.tasks.first { $0.id == "t-waiting" }?.waitingOn)
    }

    func testDroppingOnDoneClosesTheTask() async {
        let model = await boardModel()
        let outcome = await model.drop("t-needs", on: .done)
        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(server.count("POST /v1/tasks/t-needs/close"), 1)
        XCTAssertEqual(server.tasks.first { $0.id == "t-needs" }?.status, .done)
        let waiting = await model.drop("t-waiting", on: .done)
        XCTAssertEqual(waiting, .moved)
        XCTAssertNil(server.tasks.first { $0.id == "t-waiting" }?.waitingOn)
        XCTAssertEqual(server.tasks.first { $0.id == "t-waiting" }?.status, .done)
    }

    /// S5
    func testAddSendsAcceptAndUpdatesTheList() async {
        let model = makeModel()
        await model.reload()
        await model.add(model.suggestions[0])
        XCTAssertEqual(server.count("POST /v1/suggestions/s-1/accept"), 1)
        XCTAssertEqual(model.suggestions.map(\.id), ["s-2"])
        XCTAssertTrue(model.backlog.contains { $0.title == "Send the notes to Bo" })
    }

    func testSkipSendsReject() async {
        let model = makeModel()
        await model.reload()
        await model.skip(model.suggestions[1])
        XCTAssertEqual(server.count("POST /v1/suggestions/s-2/reject"), 1)
        XCTAssertEqual(model.suggestions.map(\.id), ["s-1"])
    }

    func testCloseNoteAndStatus() async throws {
        let model = makeModel()
        await model.reload()
        let closed = await model.close("t-needs", note: "checked")
        XCTAssertTrue(closed)
        await model.setShowsDone(true)
        XCTAssertTrue(model.done.contains { $0.id == "t-needs" })
        let moved = await model.setStatus("t-backlog", status: .inProgress, note: "started")
        XCTAssertTrue(moved)
        XCTAssertTrue(model.inProgress.contains { $0.id == "t-backlog" })
        let noted = await model.addNote("t-progress", note: "hello")
        XCTAssertTrue(noted)
        XCTAssertEqual(server.requests.last { $0.method == "PATCH" }?.json["note"] as? String, "hello")
    }

    /// S6
    func testEventsReloadReconnectWithTheLastSeqAndResync() async {
        let model = makeModel()
        model.start()
        defer { model.stop() }
        await waitUntil { self.server.openSocketCount == 1 && model.loaded }
        let baseline = server.count("GET /v1/tasks")

        server.tasks = server.tasks + [RemoteTask(id: "t-new", title: "Added on the Mac", status: .backlog)]
        let seq = server.publish("tasks.changed", id: "t-new")
        await waitUntil { model.backlog.contains { $0.id == "t-new" } }
        XCTAssertTrue(model.backlog.contains { $0.id == "t-new" }, "tasks.changed reloads the list")
        XCTAssertGreaterThan(server.count("GET /v1/tasks"), baseline)

        server.dropSockets()
        await waitUntil { self.server.socketURLs.count == 2 }
        XCTAssertEqual(server.socketURLs.last, "/v1/events?since=\(seq)", "the reconnect passes the last seq")

        await waitUntil { self.server.openSocketCount == 1 }
        let beforeResync = server.count("GET /v1/tasks")
        server.gapOnNextConnect = true
        server.dropSockets()
        await waitUntil { self.server.count("GET /v1/tasks") > beforeResync }
        XCTAssertGreaterThan(server.count("GET /v1/tasks"), beforeResync, "resync reloads through REST")
    }

    /// S7
    func testAnUnauthorizedAnswerDropsTheToken() async {
        let store = MemoryCredentialStore(PairedDevice(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token, deviceID: "d"))
        let app = AppModel(store: store)
        XCTAssertNotNil(app.device)
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let model = TasksModel(client: client, onUnauthorized: { app.handleUnauthorized() })
        server.tokenValid = false
        await model.reload()
        XCTAssertNil(store.load(), "the token is deleted")
        XCTAssertEqual(app.phase, .unpaired)
        XCTAssertNotNil(app.notice)
    }

    func testUnpairRevokesOnTheMacAndDeletesTheToken() async {
        let store = MemoryCredentialStore(PairedDevice(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token, deviceID: "d"))
        let app = AppModel(store: store)
        await app.unpair()
        XCTAssertEqual(server.count("DELETE /v1/devices/me"), 1)
        XCTAssertNil(store.load())
        XCTAssertEqual(app.phase, .unpaired)
    }
}
