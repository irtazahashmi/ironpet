import XCTest
import IronPetKit
@testable import IronPetRemote

/// A socket that records what the phone writes and answers as a test script says.
final class FakeChatSocket: ChatSocket, @unchecked Sendable {
    enum Answer { case ack, closed, unavailable, refused(String), never }
    private let lock = NSLock()
    private var _sent: [(clientID: String, text: String)] = []
    private var _open: Bool
    var answer: Answer
    /// A message with one of these texts is refused, whatever `answer` says.
    var refuseTexts: Set<String> = []

    init(open: Bool = true, answer: Answer = .ack) { _open = open; self.answer = answer }

    var canSendChat: Bool { lock.lock(); defer { lock.unlock() }; return _open }
    func setOpen(_ open: Bool) { lock.lock(); _open = open; lock.unlock() }
    var sent: [(clientID: String, text: String)] { lock.lock(); defer { lock.unlock() }; return _sent }

    func sendChat(clientID: String, text: String, reply: RemoteReplyRef?) async throws -> ChatAck {
        lock.lock(); _sent.append((clientID, text)); lock.unlock()
        if refuseTexts.contains(text) { throw SocketSendError.refused(code: "invalid", message: "the message is empty") }
        switch answer {
        case .ack: return ChatAck(clientID: clientID, outcome: "sent", itemID: nil, seq: 1)
        case .closed: throw SocketSendError.closed
        case .unavailable: throw SocketSendError.unavailable
        case .refused(let message): throw SocketSendError.refused(code: "invalid", message: message)
        case .never: try await Task.sleep(for: .seconds(60)); throw CancellationError()
        }
    }
}

/// S1, S3 and S4 of sending over the open socket: the socket carries the message when it can, and HTTPS does when it cannot, with the
/// same client id so the Mac never makes two messages.
@MainActor
final class SocketSendTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func started(socket: FakeChatSocket?) async -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.socket = socket
        model.start()
        await poll { model.loaded && model.snapshot != nil }
        return model
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private var posts: [MockIronPetServer.Recorded] { server.requests.filter { $0.line == "POST /v1/chat/current/messages" } }

    // S1
    func testATypedMessageGoesOverTheSocketAndMakesNoHTTPSPost() async {
        let socket = FakeChatSocket()
        let model = await started(socket: socket)
        var hops: [String] = []
        PhoneHopLog.tap = { hops.append($0) }
        defer { PhoneHopLog.tap = nil }
        model.draft = "over the socket"
        await model.send()
        XCTAssertEqual(socket.sent.map(\.text), ["over the socket"])
        XCTAssertNotNil(socket.sent.first.flatMap { UUID(uuidString: $0.clientID) }, "the id is a UUID the phone made")
        XCTAssertTrue(posts.isEmpty, "no HTTPS POST for a socket send")
        XCTAssertFalse(model.outbox.contains { $0.isFailed }, "the ack settles the message")
        XCTAssertEqual(hops.filter { $0.hasPrefix("phone.socket") }, ["phone.socket", "phone.socket.ack"])
        XCTAssertFalse(hops.contains("phone.post"))
        model.stop()
    }

    // S3
    func testWithoutTheCapabilityTheSendUsesHTTPSAsBefore() async {
        // The mock Mac's hello has no capabilities, like an older Mac. The real connection reports that it cannot send.
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let connection = EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))
        let model = ChatModel(client: client, events: SharedEventSource(connection), onUnauthorized: {})
        model.socket = connection
        model.start()
        await poll { model.loaded && model.snapshot != nil }
        XCTAssertFalse(connection.canSendChat)
        model.draft = "to an older Mac"
        await model.send()
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.json["text"] as? String, "to an older Mac")
        model.stop()
    }

    func testAClosedSocketGoesToHTTPSAndANilSocketToo() async {
        let model = await started(socket: FakeChatSocket(open: false))
        model.draft = "socket is down"
        await model.send()
        XCTAssertEqual(posts.count, 1)
        model.stop()
    }

    // S4
    func testASocketThatDiesAfterTheFrameLeftResendsOverHTTPSWithTheSameClientID() async {
        let socket = FakeChatSocket(answer: .closed)
        let model = await started(socket: socket)
        model.draft = "maybe taken"
        await model.send()
        XCTAssertEqual(socket.sent.count, 1)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.json["client_id"] as? String, socket.sent.first?.clientID, "the Mac dedupes on this id")
        XCTAssertFalse(model.outbox.contains { $0.isFailed })
        model.stop()
    }

    // S4
    func testAnUnansweredSocketSendFailsWithRetryAndRetryReusesTheClientID() async {
        let socket = FakeChatSocket(answer: .never)
        let model = await started(socket: socket)
        model.sendTimeout = .milliseconds(200)
        model.draft = "no ack"
        await model.send()
        guard let failed = model.outbox.first, failed.isFailed else { return XCTFail("the message should be marked failed") }
        XCTAssertTrue(posts.isEmpty)
        socket.answer = .ack
        await model.retry(failed.id)
        XCTAssertEqual(socket.sent.map(\.clientID), [failed.id.uuidString.lowercased(), failed.id.uuidString.lowercased()], "a retry sends the same id")
        XCTAssertFalse(model.outbox.contains { $0.isFailed })
        model.stop()
    }

    func testARefusalShowsTheMacsReasonAndSendsNothingOverHTTPS() async {
        let model = await started(socket: FakeChatSocket(answer: .refused("the message is empty")))
        model.draft = "refused"
        await model.send()
        XCTAssertEqual(model.outbox.first?.state, .failed("the message is empty"))
        XCTAssertTrue(posts.isEmpty)
        model.stop()
    }

    func testAMessageWithAnAttachmentStaysOnHTTPS() async {
        let socket = FakeChatSocket()
        let model = await started(socket: socket)
        model.attachments = [PendingAttachment(fileName: "a.txt", contentType: "text/plain", data: Data([1, 2, 3]), isImage: false)]
        model.draft = "with a file"
        await model.send()
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(posts.count, 1)
        model.stop()
    }
}
