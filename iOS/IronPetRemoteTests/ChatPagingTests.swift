import XCTest
import IronPetKit
@testable import IronPetRemote

/// The chat reads the newest page, then the page before its oldest message on scroll, so a long thread is not read whole.
@MainActor
final class ChatPagingTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        server.chat = RemoteChatSnapshot(items: (1...120).map { RemoteChatItem(id: "m-\($0)", kind: "user", date: Date(), origin: "ios", text: "m\($0)") })
    }

    override func tearDown() { server.stop() }

    private func started() async -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.start()
        await poll { model.snapshot != nil }
        return model
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testTheNewestPageLoadsAndEachScrollLoadsTheOnePageBefore() async {
        let model = await started()
        XCTAssertEqual(model.items.count, 50, "a long thread opens on its newest page")
        XCTAssertEqual(model.items.first?.id, "m-71")
        XCTAssertEqual(model.items.last?.id, "m-120")
        XCTAssertTrue(model.hasOlderHistory)

        await model.loadOlder()
        XCTAssertEqual(model.items.count, 100)
        XCTAssertEqual(model.items.first?.id, "m-21")
        XCTAssertTrue(model.hasOlderHistory)

        await model.loadOlder()
        XCTAssertEqual(model.items.count, 120)
        XCTAssertEqual(model.items.map(\.id), (1...120).map { "m-\($0)" }, "the messages stay in order with no repeats")
        XCTAssertFalse(model.hasOlderHistory)
        model.stop()
    }

    func testAReloadKeepsTheOlderPagesAlreadyLoaded() async {
        let model = await started()
        await model.loadOlder()
        XCTAssertEqual(model.items.count, 100)

        await model.refresh()
        XCTAssertEqual(model.items.count, 100, "a reload reads the newest page and keeps the older messages above it")
        XCTAssertEqual(model.items.first?.id, "m-21")
        XCTAssertEqual(model.items.last?.id, "m-120")
        model.stop()
    }

    // S8 (phone): with a cursor from the last answer, a reload sends it and takes only the messages that changed.
    func testAReloadAsksAfterTheCursorAndMergesOnlyWhatChanged() async {
        server.chatCursor = (epoch: "launch-1", seq: 10, changed: [])
        let model = await started()
        XCTAssertEqual(model.items.count, 50)

        var chat = server.chat
        chat.items[119] = RemoteChatItem(id: "m-120", kind: "user", date: Date(), origin: "ios", text: "edited")
        chat.items.append(RemoteChatItem(id: "m-121", kind: "user", date: Date(), origin: "ios", text: "m121"))
        server.chat = chat
        server.chatCursor = (epoch: "launch-1", seq: 12, changed: ["m-120", "m-121"])
        await model.refresh()

        let request = server.requests.last { $0.path == "/v1/chat/current" }
        XCTAssertTrue(request?.query.contains("after=10") ?? false)
        XCTAssertTrue(request?.query.contains("epoch=launch-1") ?? false)
        XCTAssertEqual(model.deltaReads, 1)
        XCTAssertEqual(model.items.count, 51, "the new message is appended and the page stays")
        XCTAssertEqual(model.items.first?.id, "m-71")
        XCTAssertEqual(model.items.last?.id, "m-121")
        XCTAssertEqual(model.items.first { $0.id == "m-120" }?.text, "edited")
        model.stop()
    }
}
