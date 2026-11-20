import XCTest
@testable import IronPetKit

final class AssetCacheTests: XCTestCase {
    var server: MockIronPetServer!
    var directory: URL!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-assets-\(UUID().uuidString)")
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    func testAManifestThePhoneAlreadyHasDownloadsNothingAndAChangedSpriteDownloadsOneFile() async throws {
        server.setSprite(TestSheets.png(height: 2704))
        let cache = AssetCache(directory: directory)
        let first = try await cache.sync(with: client())
        XCTAssertEqual(first.downloaded.count, 1)
        let hash = try XCTUnwrap(first.current["pet.sprite"])
        XCTAssertNotNil(cache.url(forHash: hash))
        XCTAssertEqual(server.requests.filter { $0.path.hasPrefix("/v1/assets/") && $0.path != "/v1/assets/manifest" }.count, 1)

        let again = try await cache.sync(with: client())
        XCTAssertEqual(again.downloaded, [])
        XCTAssertEqual(again.current["pet.sprite"], hash)
        XCTAssertEqual(server.count("GET /v1/assets/\(hash)"), 1, "the second sync fetched the manifest and nothing else")
        XCTAssertEqual(server.count("GET /v1/assets/manifest"), 2)

        server.setSprite(TestSheets.png(height: 2288))
        let changed = try await cache.sync(with: client())
        XCTAssertEqual(changed.downloaded.count, 1)
        XCTAssertNotEqual(changed.current["pet.sprite"], hash)
        XCTAssertEqual(server.requests.filter { $0.path.hasPrefix("/v1/assets/") && $0.path != "/v1/assets/manifest" }.count, 2)
    }

    func testTheSocketReceivesAssetsChangedAndTheNextSyncDownloadsOneFile() async throws {
        server.setSprite(TestSheets.png(height: 2704))
        let cache = AssetCache(directory: directory)
        try await cache.sync(with: client())
        let connection = EventConnection(client: client())
        var iterator = connection.signals().makeAsyncIterator()
        guard case .connected = await iterator.next() else { return XCTFail("no hello") }
        server.setSprite(TestSheets.png(height: 2288))
        server.publish(RemoteEvent.assetsChanged)
        var changed = false
        for _ in 0..<5 {
            if case .event(let event) = await iterator.next(), event.kind == RemoteEvent.assetsChanged { changed = true; break }
        }
        XCTAssertTrue(changed)
        let result = try await cache.sync(with: client())
        XCTAssertEqual(result.downloaded.count, 1)
    }

    func testABadDownloadIsNotKept() async throws {
        server.setSprite(Data("this is not a sheet".utf8))
        let cache = AssetCache(directory: directory)
        let result = try await cache.sync(with: client())
        XCTAssertEqual(result.downloaded, [])
        XCTAssertNil(result.current["pet.sprite"])
    }

    func testAHashLeavesAfterASevenDaysUnlisted() async throws {
        server.setSprite(TestSheets.png(height: 2704))
        var clock = Date()
        let cache = AssetCache(directory: directory, now: { clock })
        let old = try await cache.sync(with: client()).current["pet.sprite"]!
        server.setSprite(TestSheets.png(height: 2288))
        clock = clock.addingTimeInterval(3 * 24 * 3600)
        try await cache.sync(with: client())
        XCTAssertNotNil(cache.url(forHash: old), "unlisted for three days: kept")
        clock = clock.addingTimeInterval(5 * 24 * 3600)
        try await cache.sync(with: client())
        XCTAssertNil(cache.url(forHash: old), "unlisted for eight days: deleted")
    }
}
