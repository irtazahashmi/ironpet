import CoreGraphics
import IronPetKit
import XCTest
@testable import IronPetRemote

private func waitUntil(_ timeout: Double = 30, _ condition: @escaping @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// S1 on the phone: the shared `Atlas` cuts the same frames from the two sheet sizes as it does in `swift test` on the Mac.
final class SharedAtlasTests: XCTestCase {
    func testTheGhostAndCodexSheetsYieldTheExpectedFrames() throws {
        let ghost = try XCTUnwrap(Atlas.load(data: TestSheets.png(height: 2704)))
        let codex = try XCTUnwrap(Atlas.load(data: TestSheets.png(height: 2288)))
        XCTAssertEqual(ghost.rows.count, 13)
        XCTAssertEqual(codex.rows.count, 11)
        XCTAssertEqual(ghost.look.count, 16)
        XCTAssertTrue(ghost.has(.drinking))
        XCTAssertFalse(codex.has(.drinking))
        for atlas in [ghost, codex] {
            let color = TestSheets.center(of: try XCTUnwrap(atlas.frame(.failed, 3)))
            let expected = TestSheets.color(row: 5, column: 3)
            XCTAssertEqual([color.r, color.g, color.b], [expected.r, expected.g, expected.b])
        }
        XCTAssertNil(Atlas.load(data: TestSheets.png(height: 2000)))
    }
}

/// S2: the cache against the mock.
final class AssetCacheOnPhoneTests: XCTestCase {
    var server: MockIronPetServer!
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-phone-assets-\(UUID().uuidString)")
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    private var downloads: Int { server.requests.filter { $0.path.hasPrefix("/v1/assets/") && $0.path != "/v1/assets/manifest" }.count }

    func testAKnownManifestDownloadsNothingAndAChangedSpriteDownloadsOneFile() async throws {
        server.setSprite(TestSheets.png(height: 2704))
        let cache = AssetCache(directory: directory)
        try await cache.sync(with: client())
        XCTAssertEqual(downloads, 1)
        let again = try await cache.sync(with: client())
        XCTAssertEqual(again.downloaded, [])
        XCTAssertEqual(downloads, 1)
        server.setSprite(TestSheets.png(height: 2288))
        let changed = try await cache.sync(with: client())
        XCTAssertEqual(changed.downloaded.count, 1)
        XCTAssertEqual(downloads, 2)
    }
}

@MainActor
final class PetModelTests: XCTestCase {
    var server: MockIronPetServer!
    var directory: URL!
    var unauthorized = 0

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        server.setSprite(TestSheets.png(height: 2704))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-phone-pet-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    private func events(_ client: IronPetClient) -> SharedEventSource {
        SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
    }

    private func petModel(_ client: IronPetClient, _ events: SharedEventSource) -> PetModel {
        PetModel(client: client, events: events, cache: AssetCache(directory: directory), onUnauthorized: { [unowned self] in unauthorized += 1 })
    }

    /// S6
    func testAPetMoodFailedEventPlaysRowFive() async {
        let client = client()
        let model = petModel(client, events(client))
        model.start()
        await waitUntil { model.atlas != nil && model.pet != nil }
        XCTAssertEqual(model.row.index, 0, "idle plays row 0")
        server.pet = RemotePet(name: "Ghost", mood: "failed", badge: 1, tricks: ["Wave"])
        server.publish(RemoteEvent.petMood, id: "failed")
        await waitUntil { model.mood == "failed" }
        XCTAssertEqual(model.row.index, 5)
        await waitUntil { model.badge == 1 }
        XCTAssertEqual(model.badge, 1)
        model.stop()
    }

    /// Step 3 of #190: the Mac's accent reaches the phone's tint, and a Mac that sends none leaves the system blue.
    func testThePetModelTakesTheMacAccentAndKeepsTheDefaultWithoutOne() async {
        let client = client()
        let model = petModel(client, events(client))
        model.start()
        await waitUntil { model.pet != nil }
        XCTAssertNil(model.accent, "no accent from the Mac means the system blue")
        server.pet = RemotePet(name: "Ghost", accent: "#FF9500", accentDark: "#FF9F0A")
        await model.reloadPet(applyMood: false)
        XCTAssertNotNil(model.accent)
        server.pet = RemotePet(name: "Ghost")
        await model.reloadPet(applyMood: false)
        XCTAssertNil(model.accent, "an accent the Mac stops sending goes back to the default")
        model.stop()
    }

    func testASheetWithoutTheDrinkingRowPlaysWavingAndTheSpriteChangesWithTheAssetsEvent() async {
        let client = client()
        let model = petModel(client, events(client))
        model.start()
        await waitUntil { model.atlas != nil }
        server.setSprite(TestSheets.png(height: 2288))
        server.publish(RemoteEvent.assetsChanged)
        await waitUntil { model.atlas?.has(.drinking) == false }
        XCTAssertEqual(model.atlas?.rows.count, 11)
        server.publish(RemoteEvent.petMood, id: "drinking")
        await waitUntil { model.mood == "drinking" }
        XCTAssertEqual(model.row, .waving)
        model.stop()
    }

    func testTricksAndBubbleButtonsGoToTheMac() async throws {
        let client = client()
        let model = petModel(client, events(client))
        await model.reload()
        XCTAssertEqual(model.bubbles.map(\.id), ["session:a", "approval:1"])
        let approval = try XCTUnwrap(model.bubbles.last)
        XCTAssertTrue(approval.macOnly)
        XCTAssertTrue(approval.actions.isEmpty, "the phone shows Answer on the Mac, not buttons")
        let first = try XCTUnwrap(model.bubbles.first)
        await model.press(first, first.actions[0])
        XCTAssertEqual(server.count("POST /v1/bubbles/session:a/actions/act-open"), 1)
        XCTAssertEqual(model.bubbles.map(\.id), ["approval:1"])
        await model.perform(trick: "Wave")
        XCTAssertEqual(server.count("POST /v1/pet/tricks/Wave"), 1)
        XCTAssertEqual(model.lastTrick, "Wave")
    }

    func testFiveModelsShareOneSocket() async {
        let client = client()
        let shared = events(client)
        let pet = petModel(client, shared)
        let alerts = AlertsModel(client: client, events: shared, onUnauthorized: {})
        let agents = AgentsModel(client: client, events: shared, onUnauthorized: {})
        let today = TodayModel(client: client, events: shared, onUnauthorized: {})
        for model in [pet, alerts, agents, today] as [SocketModel] { model.start() }
        await waitUntil { alerts.loaded && agents.loaded && today.loaded && pet.loaded }
        await waitUntil { self.server.openSocketCount >= 1 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.openSocketCount, 1)
        for model in [pet, alerts, agents, today] as [SocketModel] { model.stop() }
    }
}

@MainActor
final class AgentsAlertsTodayTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() async throws { server.stop() }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    private func events(_ client: IronPetClient) -> SharedEventSource {
        SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
    }

    func testNeedsInputComesFirstAndAcknowledgeClearsADoneSession() async throws {
        let client = client()
        let model = AgentsModel(client: client, events: events(client), onUnauthorized: {})
        model.start()
        await waitUntil { model.loaded }
        XCTAssertEqual(model.agents.first?.status, .needsInput)
        XCTAssertEqual(model.needsInput.map(\.id), ["s-needs"])
        XCTAssertEqual(model.running.map(\.id), ["s-run"])
        XCTAssertEqual(model.finished.map(\.id), ["s-done"])
        let detail = await model.detail("s-done")
        XCTAssertEqual(detail?.lastResponse, "Updated the docs.")
        await model.acknowledge(try XCTUnwrap(model.finished.first))
        XCTAssertEqual(server.count("POST /v1/agents/s-done/acknowledge"), 1)
        XCTAssertTrue(model.finished.isEmpty)
        await model.ask(try XCTUnwrap(model.needsInput.first))
        XCTAssertEqual(server.count("POST /v1/agents/s-needs/ask"), 1)
        XCTAssertNotNil(model.notice)
        model.stop()
    }

    func testAnAlertsChangedEventReloadsTheListAndDismissWorks() async throws {
        let client = client()
        let model = AlertsModel(client: client, events: events(client), onUnauthorized: {})
        model.start()
        await waitUntil { model.loaded }
        XCTAssertEqual(model.alerts.map(\.id), ["al-ci", "al-pr"])
        server.alerts = [RemoteAlert(id: "new", title: "New alert")] + server.alerts
        server.publish(RemoteEvent.alertsChanged)
        await waitUntil { model.alerts.count == 3 }
        XCTAssertEqual(model.alerts.first?.id, "new")
        await model.dismiss(model.alerts[0])
        XCTAssertEqual(server.count("POST /v1/alerts/new/dismiss"), 1)
        await waitUntil { model.alerts.count == 2 }
        await model.ask(model.alerts[0])
        XCTAssertEqual(server.count("POST /v1/alerts/al-ci/ask"), 1)
        await model.dismissAll()
        XCTAssertEqual(server.count("POST /v1/alerts/dismiss-all"), 1)
        XCTAssertTrue(model.alerts.isEmpty)
        model.stop()
    }

    /// S8: the target mapping and the kind switch.
    func testTodayTargetsOpenTheRightTabAndTheKindSwitchesTheList() async throws {
        XCTAssertEqual(AppTab.tab(for: TodayTarget(type: .task, id: "t")), .tasks, "an older Mac's task row opens the Inbox")
        XCTAssertEqual(AppTab.tab(for: TodayTarget(type: .session, id: "s")), .agents)
        XCTAssertEqual(AppTab.tab(for: TodayTarget(type: .alert, id: "a")), .more)
        XCTAssertEqual(AppTab.tab(for: TodayTarget(type: .meeting, id: "m")), .more)
        XCTAssertEqual(MoreDestination.destination(for: TodayTarget(type: .alert, id: "a")), .alerts)
        XCTAssertEqual(MoreDestination.destination(for: TodayTarget(type: .meeting, id: "m")), .meetings)
        XCTAssertNil(MoreDestination.destination(for: TodayTarget(type: .task, id: "t")))
        let client = client()
        let model = TodayModel(client: client, events: events(client), onUnauthorized: {})
        await model.reload()
        XCTAssertEqual(model.today?.kind, "brief")
        XCTAssertEqual(model.today?.sections.map(\.id), ["agents", "alerts", "meetings"])
        model.kind = .recap
        await waitUntil { model.today?.kind == "recap" }
        XCTAssertEqual(model.today?.sections.map(\.id), ["done"])
        XCTAssertEqual(server.requests.filter { $0.path == "/v1/today" }.map(\.query), ["kind=brief", "kind=recap"])
    }
}
