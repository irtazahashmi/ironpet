import IronPetKit
import XCTest
@testable import IronPetRemote

@MainActor
final class PetPresencePublishTests: XCTestCase {
    var server: MockIronPetServer!
    var directory: URL!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        server.setSprite(TestSheets.png(height: 2704))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-presence-\(UUID().uuidString)")
        PetSnapshotStore.clear()
    }

    override func tearDown() async throws {
        server.stop()
        PetSnapshotStore.clear()
        try? FileManager.default.removeItem(at: directory)
    }

    func testReloadWritesASnapshotForTheWidget() async throws {
        server.pet = RemotePet(name: "Ghost", mood: "working", badge: 2, tricks: ["Wave"])
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = PetModel(client: client, events: events, cache: AssetCache(directory: directory), onUnauthorized: {})
        await model.reload()
        let snapshot = try XCTUnwrap(PetSnapshotStore.load())
        XCTAssertEqual(snapshot.name, "Ghost")
        XCTAssertEqual(snapshot.mood, "working")
        XCTAssertEqual(snapshot.badge, 2)
        XCTAssertTrue(snapshot.needsAttention)
        model.stop()
    }
}
