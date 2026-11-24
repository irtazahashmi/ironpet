import XCTest
import IronPetKit
@testable import IronPetRemote

/// The chat the phone saved last time shows at launch, and an unchanged Mac answers 304 to its ETag.
@MainActor
final class ChatCacheTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        server.chat = RemoteChatSnapshot(title: "Saved chat", items: (1...5).map { RemoteChatItem(id: "c-\($0)", kind: "user", date: Date(timeIntervalSince1970: 1_700_000_000), origin: "ios", text: "saved \($0)") })
    }

    override func tearDown() { server.stop() }

    private func model(cache: any ChatCaching) -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.useCache(cache)
        return model
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testTheFileCacheRoundTripsAndIsLeftOutOfBackups() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = SavedChat(etag: "\"abc\"", snapshot: server.chat, hasOlderHistory: true)
        let cache = FileChatCache(url: url)
        cache.save(saved)
        XCTAssertEqual(FileChatCache(url: url).load(), saved)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "the saved chat never reaches a backup")
    }

    func testASavedChatShowsAtLaunchEvenWhenTheMacIsOffline() {
        let cache = MemoryChatCache(SavedChat(etag: "\"abc\"", snapshot: server.chat, hasOlderHistory: false))
        server.stop()
        let launched = model(cache: cache)
        XCTAssertEqual(launched.items.map(\.id), ["c-1", "c-2", "c-3", "c-4", "c-5"], "the phone shows what it saw last")
        XCTAssertEqual(launched.title, "Saved chat")
        XCTAssertFalse(launched.running)
    }

    func testTheSavedApprovalsAreNotShownAfterALaunch() {
        var page = server.chat
        page.running = true
        page.approvals = [RemoteApproval(id: "a-1", title: "Run the tests", detail: "npm test")]
        XCTAssertTrue(ChatModel.savable(page).approvals.isEmpty, "approvals are the live Mac's, never saved")
        XCTAssertFalse(ChatModel.savable(page).running)
    }

    func testAnUnchangedChatAnswers304AndTheSavedPageIsKept() async {
        let cache = MemoryChatCache()
        let first = model(cache: cache)
        first.start()
        await poll { first.snapshot != nil }
        first.stop()
        let etag = cache.load()?.etag
        XCTAssertNotNil(etag, "the first read saved the Mac's ETag")

        let second = model(cache: cache)
        second.start()
        await poll { server.requests.contains { $0.path == "/v1/chat/current" && $0.headers["if-none-match"] == etag } }
        XCTAssertTrue(server.requests.contains { $0.path == "/v1/chat/current" && $0.headers["if-none-match"] == etag }, "the launch sends the saved ETag")
        XCTAssertEqual(second.items.map(\.id), ["c-1", "c-2", "c-3", "c-4", "c-5"])
        second.stop()
    }

    func testAChangedChatAnswers200AndReplacesTheSavedPage() async {
        let cache = MemoryChatCache()
        let first = model(cache: cache)
        first.start()
        await poll { first.snapshot != nil }
        first.stop()
        let oldETag = cache.load()?.etag

        server.pushUserItem(text: "sent from the Mac", origin: "mac")
        let second = model(cache: cache)
        second.start()
        await poll { second.items.count == 6 }
        second.stop()
        XCTAssertEqual(second.items.count, 6, "a changed chat is read in full")
        XCTAssertNotEqual(cache.load()?.etag, oldETag, "the saved ETag follows the new page")
        XCTAssertEqual(cache.load()?.snapshot.items.count, 6)
    }
}
