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
final class InboxModelTests: XCTestCase {
    var server: MockIronPetServer!
    var unauthorized = 0

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() async throws { server.stop() }

    func makeModel() -> InboxModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))
        return InboxModel(client: client, events: events, onUnauthorized: { [unowned self] in unauthorized += 1 })
    }

    func testTheInboxListsTheMacsItems() async {
        let model = makeModel()
        await model.reload()
        XCTAssertEqual(model.items.map(\.id), ["s-1", "s-2"])
    }

    func testRowsNameTheOriginAndLinkTheSource() {
        let meeting = RemoteSuggestion(id: "m", title: "Send the notes", origin: "meeting", url: "https://example.com/meeting")
        XCTAssertEqual(meeting.originLabel, "Meeting")
        XCTAssertNil(meeting.sourceLink, "a meeting's source is a folder on the Mac")
        let automation = RemoteSuggestion(id: "a", title: "Fix the build", origin: "automation", originDetail: "CI watcher", url: "https://example.com/pr/1")
        XCTAssertEqual(automation.originLabel, "From CI watcher")
        XCTAssertEqual(automation.sourceLink?.absoluteString, "https://example.com/pr/1")
        XCTAssertNil(RemoteSuggestion(id: "f", title: "File", origin: "automation", url: "file:///Users/me/notes").sourceLink)
        XCTAssertEqual(RemoteSuggestion(id: "x", title: "Old", origin: "task-scan").originLabel, "From an automation")
    }

    /// S6: an older Mac sends fields the phone no longer knows, and an origin it no longer uses.
    func testAnOldMacsItemsDecodeAndIgnoreTheExtraKeys() throws {
        let json = """
        {"suggestions": [{
          "id": "u-1", "title": "Reply from legal", "created": "2026-11-20T09:30:00Z", "origin": "task-scan", "origin_detail": "Task scan",
          "update": {"task_id": "t-1", "task_title": "Reply from legal", "note": "Legal answered.", "status": "done"},
          "clarify": {"kind": "project", "title": "Legal"}, "notes": "", "unknown_future_key": [1, 2]
        }]}
        """
        let list = try WireJSON.makeDecoder().decode(SuggestionListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(list.suggestions.map(\.id), ["u-1"])
        XCTAssertEqual(list.suggestions[0].origin, "task-scan")
        XCTAssertEqual(list.suggestions[0].originLabel, "From Task scan")
    }

    /// S6: the Mac answers 404 (no inbox route), 501, an error, or something unreadable. The phone shows an empty Inbox and no banner.
    func testAMacWithoutTheInboxRouteShowsAnEmptyInboxAndNoError() async {
        for status in [404, 501, 500, 200] {
            server.brokenRoutes = [APIPath.suggestions: status]
            let model = makeModel()
            await model.refresh()
            XCTAssertTrue(model.items.isEmpty, "status \(status)")
            XCTAssertTrue(model.loaded, "status \(status)")
            XCTAssertFalse(model.showsLoadError, "status \(status)")
            XCTAssertNil(model.errorMessage, "status \(status)")
            XCTAssertFalse(model.network.stripVisible, "status \(status)")
        }
    }

    func testDoneTakesTheItemOffTheListAndItStaysOffAfterAReload() async {
        let model = makeModel()
        await model.reload()
        await model.done(model.items[0])
        XCTAssertEqual(server.count("POST /v1/suggestions/s-1/accept"), 1)
        XCTAssertEqual(model.items.map(\.id), ["s-2"])
        await model.reload()
        XCTAssertEqual(model.items.map(\.id), ["s-2"])
        XCTAssertEqual(server.suggestions.map(\.id), ["s-2"])
    }

    func testRemoveTakesTheItemOffTheListAndItStaysOffAfterAReload() async {
        let model = makeModel()
        await model.reload()
        await model.remove(model.items[1])
        XCTAssertEqual(server.count("POST /v1/suggestions/s-2/reject"), 1)
        XCTAssertEqual(model.items.map(\.id), ["s-1"])
        await model.reload()
        XCTAssertEqual(model.items.map(\.id), ["s-1"])
    }

    func testAFailedChangePutsTheItemBackAndShowsTheReason() async {
        let model = makeModel()
        await model.reload()
        server.brokenRoutes = [APIPath.acceptSuggestion("s-1"): 500]
        await model.done(model.items[0])
        XCTAssertEqual(model.items.map(\.id), ["s-1", "s-2"])
        XCTAssertNotNil(model.errorMessage)
    }

    func testSuggestionsChangedReloadsTheInboxAndAReconnectResumesFromTheLastSeq() async {
        let model = makeModel()
        model.start()
        defer { model.stop() }
        await waitUntil { self.server.openSocketCount == 1 && model.loaded }
        let baseline = server.count("GET /v1/suggestions")

        server.suggestions = server.suggestions + [RemoteSuggestion(id: "s-new", title: "Added on the Mac")]
        let seq = server.publish(RemoteEvent.suggestionsChanged)
        await waitUntil { model.items.contains { $0.id == "s-new" } }
        XCTAssertTrue(model.items.contains { $0.id == "s-new" }, "suggestions.changed reloads the list")
        XCTAssertGreaterThan(server.count("GET /v1/suggestions"), baseline)

        server.dropSockets()
        await waitUntil { self.server.socketURLs.count == 2 }
        XCTAssertEqual(server.socketURLs.last, "/v1/events?since=\(seq)", "the reconnect passes the last seq")

        await waitUntil { self.server.openSocketCount == 1 }
        let beforeResync = server.count("GET /v1/suggestions")
        server.gapOnNextConnect = true
        server.dropSockets()
        await waitUntil { self.server.count("GET /v1/suggestions") > beforeResync }
        XCTAssertGreaterThan(server.count("GET /v1/suggestions"), beforeResync, "resync reloads through REST")
    }

    /// S7
    func testAnUnauthorizedAnswerDropsTheToken() async {
        let store = MemoryCredentialStore(PairedDevice(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token, deviceID: "d"))
        let app = AppModel(store: store)
        XCTAssertNotNil(app.device)
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let model = InboxModel(client: client, events: EventConnection(client: client), onUnauthorized: { app.handleUnauthorized() })
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
