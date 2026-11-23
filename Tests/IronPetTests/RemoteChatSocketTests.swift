import IronPetKit
import XCTest
@testable import IronPet
@testable import IronPetCore

/// A phone sends typed messages over the event socket with a client id of its own, and the Mac answers with an ack. The phone side is
/// the real `EventConnection`, the Mac side the real listener with a scripted agent.
@MainActor
final class RemoteChatSocketTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var chat: ChatSession!
    private var connection: EventConnection!
    private var client: IronPetClient!
    private var token = ""
    private var turns: [ACPTurn] = []
    private var previousThreads: URL!
    private var threads: URL!
    private var reading: Task<Void, Never>?

    override func setUp() async throws {
        TestMemory.isolate()
        previousThreads = ThreadStore.directory
        threads = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-socket-send-threads-\(UUID().uuidString)")
        ThreadStore.directory = threads
        chat = ChatSession(restore: false, speech: SpeechPlayer())
        chat.workspace = FileManager.default.temporaryDirectory
        turns = []
        chat.turnRunner = { [unowned self] turn, _ in turns.append(turn) }
        h = RemoteServerHarness(chat: chat)
        try await h.start()
        token = try await h.pairDevice().token
        client = IronPetClient(endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(h.port)")!), token: token)
        connection = EventConnection(client: client)
        let signals = connection.signals()
        reading = Task { for await _ in signals {} }
        try await waitUntilOpen()
    }

    override func tearDown() async throws {
        reading?.cancel()
        await h.stop()
        ThreadStore.directory = previousThreads
        try? FileManager.default.removeItem(at: threads)
    }

    private func waitUntilOpen() async throws {
        for _ in 0..<200 where !connection.canSendChat { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(connection.canSendChat, "the hello frame announces chat.send")
    }

    private var userTexts: [String] {
        chat.items.compactMap { if case .user(let text) = $0.kind { text } else { nil } }
    }

    // S1
    func testAMessageGoesOverTheSocketIsAckedAndNeverPostsOverHTTPS() async throws {
        let id = UUID().uuidString.lowercased()
        let ack = try await connection.sendChat(clientID: id, text: "hello over the socket", reply: nil)
        XCTAssertEqual(ack.clientID, id)
        XCTAssertEqual(ack.outcome, "sent")
        XCTAssertEqual(ack.seq, h.events.lastSeq)
        let item = try XCTUnwrap(chat.items.last { if case .user = $0.kind { true } else { false } })
        XCTAssertEqual(ack.itemID, item.id.uuidString)
        XCTAssertEqual(item.origin, "ios")
        XCTAssertEqual(turns.map(\.prompt), ["hello over the socket"])
        let posts = h.service.store.accessLog().filter { $0.method == "POST" && $0.route.hasPrefix("/v1/chat") }
        XCTAssertTrue(posts.isEmpty, "no HTTPS POST for a socket send: \(posts.map(\.route))")
    }

    // S2
    func testAResendWithTheSameClientIDCreatesOneMessage() async throws {
        let id = UUID().uuidString.lowercased()
        let first = try await connection.sendChat(clientID: id, text: "once only", reply: nil)
        let second = try await connection.sendChat(clientID: id, text: "once only", reply: nil)
        XCTAssertEqual(second, first)
        XCTAssertEqual(userTexts, ["once only"])
        XCTAssertEqual(turns.count, 1)
        // The same id over HTTPS, as a retry after the socket dropped, is the same message too.
        let http = try await h.request("POST", "/v1/chat/current/messages", token: token, body: ["text": "once only", "client_id": id])
        XCTAssertEqual(http.status, 200)
        XCTAssertEqual(userTexts, ["once only"])
        XCTAssertEqual(turns.count, 1)
        // Another id is another message. The turn is still running, so it waits in the queue.
        _ = try await connection.sendChat(clientID: UUID().uuidString.lowercased(), text: "second", reply: nil)
        XCTAssertEqual(chat.queue.map(\.text), ["second"])
    }

    // S2
    func testTwoFramesWithOneClientIDAtTheSameTimeCreateOneMessage() async throws {
        let id = UUID().uuidString.lowercased()
        let connection = self.connection!
        // The second call takes over the wait for the ack. The Mac still sees two frames with one id.
        let first = Task { try? await connection.sendChat(clientID: id, text: "race", reply: nil) }
        let second = Task { try? await connection.sendChat(clientID: id, text: "race", reply: nil) }
        _ = await (first.value, second.value)
        for _ in 0..<100 where userTexts.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(userTexts, ["race"])
        XCTAssertEqual(turns.count, 1)
    }

    func testABadClientIDOrAnEmptyMessageIsRefusedWithAReasonAndSendsNothing() async throws {
        do {
            _ = try await connection.sendChat(clientID: "not-a-uuid", text: "x", reply: nil)
            XCTFail("expected a refusal")
        } catch SocketSendError.refused(let code, _) { XCTAssertEqual(code, "invalid") }
        do {
            _ = try await connection.sendChat(clientID: UUID().uuidString, text: "  ", reply: nil)
            XCTFail("expected a refusal")
        } catch SocketSendError.refused(let code, _) { XCTAssertEqual(code, "invalid") }
        XCTAssertTrue(userTexts.isEmpty)
    }

    func testAFailedSendIsNotRememberedSoItsRetryRuns() async throws {
        let id = UUID().uuidString.lowercased()
        _ = try? await connection.sendChat(clientID: id, text: " ", reply: nil)
        let ack = try await connection.sendChat(clientID: id, text: "now with text", reply: nil)
        XCTAssertEqual(ack.outcome, "sent")
        XCTAssertEqual(userTexts, ["now with text"])
    }

    func testAMessageDuringATurnIsAckedAsQueuedWithoutAnItemID() async throws {
        _ = try await connection.sendChat(clientID: UUID().uuidString.lowercased(), text: "first", reply: nil)
        let ack = try await connection.sendChat(clientID: UUID().uuidString.lowercased(), text: "second", reply: nil)
        XCTAssertEqual(ack.outcome, "queued")
        XCTAssertNil(ack.itemID)
    }

    func testAClosedSocketCannotSendAndAnOpenOneWithoutTheCapabilityCannotEither() async throws {
        reading?.cancel()
        await h.stop()
        for _ in 0..<100 where connection.canSendChat { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(connection.canSendChat)
        do {
            _ = try await connection.sendChat(clientID: UUID().uuidString.lowercased(), text: "x", reply: nil)
            XCTFail("expected unavailable")
        } catch { XCTAssertEqual(error as? SocketSendError, .unavailable) }
    }
}
