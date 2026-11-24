import XCTest
import IronPetKit
@testable import IronPetRemote

/// Messages typed while the phone cannot reach the Mac wait in a saved outbox and go out in order after the reconnect. The Mac is
/// out of reach here because the client points at a port nobody listens on, and the fake socket stands for the event socket.
@MainActor
final class OutboxTests: XCTestCase {
    private let deadEndpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!)

    private func model(socket: FakeChatSocket, store: MemoryOutboxStore, now: @escaping () -> Date = Date.init) -> ChatModel {
        let client = IronPetClient(endpoint: deadEndpoint, token: "t")
        let events = SharedEventSource(EventConnection(client: client))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.socket = socket
        model.now = now
        model.useOutbox(store)
        return model
    }

    private func type(_ texts: [String], into model: ChatModel) async {
        for text in texts {
            model.draft = text
            await model.send()
        }
    }

    // S1
    func testMessagesTypedOfflineWaitInOrderAndGoOutOnceEachAfterTheReconnect() async {
        let socket = FakeChatSocket(open: false)
        let store = MemoryOutboxStore()
        let model = model(socket: socket, store: store)
        await type(["one", "two", "three"], into: model)
        XCTAssertEqual(model.outbox.map(\.text), ["one", "two", "three"])
        XCTAssertTrue(model.outbox.allSatisfy(\.isWaiting), "each shows as waiting to send")
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(store.records.map(\.text), ["one", "two", "three"])
        XCTAssertFalse(model.awaitingReply, "a waiting message does not show the typing row")

        socket.setOpen(true)
        await model.flushOutbox()
        XCTAssertEqual(socket.sent.map(\.text), ["one", "two", "three"], "in order, each once")
        XCTAssertEqual(Set(socket.sent.map(\.clientID)).count, 3)
        XCTAssertFalse(model.outbox.contains { $0.isWaiting || $0.isFailed })
        XCTAssertTrue(store.records.isEmpty, "a sent message leaves the file")
    }

    func testAMessageTypedWhileOthersWaitGoesBehindThem() async {
        let socket = FakeChatSocket(open: false)
        let model = model(socket: socket, store: MemoryOutboxStore())
        await type(["first"], into: model)
        socket.setOpen(true)
        // The connection is back, but "first" has not been flushed yet. A new message must not overtake it.
        await type(["second"], into: model)
        await model.flushOutbox()
        XCTAssertEqual(socket.sent.map(\.text), ["first", "second"])
    }

    func testTheFlushStopsAtTheFirstMessageThatCannotReachTheMac() async {
        let socket = FakeChatSocket(open: false)
        let store = MemoryOutboxStore()
        let model = model(socket: socket, store: store)
        await type(["a", "b"], into: model)
        await model.flushOutbox()
        XCTAssertEqual(model.outbox.map(\.state), [.waiting, .waiting], "still unreachable: nothing is lost or reordered")
        XCTAssertEqual(store.records.count, 2)
    }

    // S2
    func testWaitingMessagesSurviveARelaunchAndSendAfterTheReconnect() async {
        let store = MemoryOutboxStore()
        let before = model(socket: FakeChatSocket(open: false), store: store)
        await type(["kept 1", "kept 2"], into: before)

        let socket = FakeChatSocket(open: false)
        let after = model(socket: socket, store: store)
        XCTAssertEqual(after.outbox.map(\.text), ["kept 1", "kept 2"])
        XCTAssertTrue(after.outbox.allSatisfy(\.isWaiting))
        XCTAssertEqual(after.outbox.map(\.id), before.outbox.map(\.id), "the client ids carry over, so the Mac can dedupe")

        socket.setOpen(true)
        await after.flushOutbox()
        XCTAssertEqual(socket.sent.map(\.text), ["kept 1", "kept 2"])
        XCTAssertEqual(socket.sent.map(\.clientID), before.outbox.map { $0.id.uuidString.lowercased() })
    }

    func testTheFileStoreRoundTripsAndKeepsOnlyTheMessageFields() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileOutboxStore(url: url)
        let record = OutboxRecord(id: UUID(), text: "hello", date: Date(timeIntervalSince1970: 1_700_000_000), queuedAt: Date(timeIntervalSince1970: 1_700_000_001), replyItemID: "m-1", replySelection: "part", failure: nil)
        store.save([record])
        XCTAssertEqual(FileOutboxStore(url: url).load(), [record])
        let keys = Set((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])?.first?.keys.map { $0 } ?? [])
        XCTAssertEqual(keys, ["id", "text", "date", "queuedAt", "replyItemID", "replySelection"])
        store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // S3, phone side. The Mac side is `RemoteChatSocketTests.testAResendOnANewSocketAfterALostAckCreatesOneMessage`.
    func testAResendAfterALostAckUsesTheSameClientID() async {
        let socket = FakeChatSocket(open: true, answer: .closed)
        let model = model(socket: socket, store: MemoryOutboxStore())
        await type(["maybe taken"], into: model)
        XCTAssertEqual(model.outbox.first?.state, .waiting, "the frame left, the ack never came, and HTTPS is unreachable too")
        let id = model.outbox[0].id.uuidString.lowercased()
        socket.answer = .ack
        await model.flushOutbox()
        XCTAssertEqual(socket.sent.map(\.clientID), [id, id])
    }

    // S4
    func testADeletedWaitingMessageNeverReachesTheMac() async {
        let socket = FakeChatSocket(open: false)
        let store = MemoryOutboxStore()
        let model = model(socket: socket, store: store)
        await type(["keep", "drop"], into: model)
        model.deleteQueued(model.outbox[1].id)
        XCTAssertEqual(model.outbox.map(\.text), ["keep"])
        XCTAssertEqual(store.records.map(\.text), ["keep"])
        socket.setOpen(true)
        await model.flushOutbox()
        XCTAssertEqual(socket.sent.map(\.text), ["keep"])
    }

    // S5
    func testAMessageOlderThanTheLimitFailsWithRetryAndIsNotSentOnItsOwn() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let socket = FakeChatSocket(open: false)
        let store = MemoryOutboxStore()
        let model = model(socket: socket, store: store, now: { clock })
        await type(["old", "newer"], into: model)
        clock = clock.addingTimeInterval(ChatModel.maxWaitingAge + 1)
        await type(["fresh"], into: model)
        socket.setOpen(true)
        await model.flushOutbox()
        XCTAssertEqual(socket.sent.map(\.text), ["fresh"], "the two that waited past 24 hours are not sent")
        XCTAssertEqual(model.outbox.filter(\.isFailed).map(\.text), ["old", "newer"])
        XCTAssertEqual(store.records.map(\.text), ["old", "newer"], "they stay saved with their reason")
        await model.flushOutbox()
        XCTAssertEqual(socket.sent.count, 1, "a second flush does not pick them up")
        // Retry is the user's choice, and it sends.
        await model.retry(model.outbox[0].id)
        XCTAssertEqual(socket.sent.map(\.text), ["fresh", "old"])
    }

    // S5
    func testAMessageTheMacRefusesFailsWithItsReasonAndTheFlushGoesOn() async {
        let socket = FakeChatSocket(open: false)
        let store = MemoryOutboxStore()
        let model = model(socket: socket, store: store)
        await type(["bad", "good"], into: model)
        socket.refuseTexts = ["bad"]
        socket.setOpen(true)
        await model.flushOutbox()
        XCTAssertEqual(model.outbox.first?.state, .failed("the message is empty"))
        XCTAssertEqual(socket.sent.map(\.text), ["bad", "good"])
        XCTAssertEqual(store.records.map(\.text), ["bad"])
        XCTAssertEqual(store.records.first?.failure, "the message is empty")
    }

    func testAMessageWithAnAttachmentStillFailsOfflineAsBefore() async {
        let model = model(socket: FakeChatSocket(open: false), store: MemoryOutboxStore())
        model.attachments = [PendingAttachment(fileName: "a.txt", contentType: "text/plain", data: Data([1]), isImage: false)]
        model.draft = "with a file"
        await model.send()
        XCTAssertTrue(model.outbox.isEmpty, "the upload failed, so nothing waits and the composer has its content back")
        XCTAssertEqual(model.draft, "with a file")
        XCTAssertEqual(model.attachments.count, 1)
    }

    func testTheOutboxHoldsAtMostOneHundredMessages() async {
        let model = model(socket: FakeChatSocket(open: false), store: MemoryOutboxStore())
        for n in 0..<ChatModel.outboxCapacity { model.draft = "m\(n)"; await model.send() }
        XCTAssertEqual(model.outbox.filter(\.isWaiting).count, ChatModel.outboxCapacity)
        model.draft = "one too many"
        await model.send()
        XCTAssertEqual(model.outbox.last?.isFailed, true)
        XCTAssertEqual(model.outbox.filter(\.isWaiting).count, ChatModel.outboxCapacity)
    }

    // A relay answers 502, 503 or 504 when it cannot reach the Mac. Other statuses come from the Mac.
    func testARelayGatewayErrorQueuesTheMessageButAMacErrorFailsIt() async throws {
        let server = MockIronPetServer()
        try server.start()
        defer { server.stop() }
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        // A new model for each status, since a message typed behind a waiting one waits without being tried.
        for status in [502, 503, 504, 500, 409] {
            let model = ChatModel(client: client, events: SharedEventSource(EventConnection(client: client)), onUnauthorized: {})
            model.socket = FakeChatSocket(open: false)
            model.useOutbox(MemoryOutboxStore())
            server.brokenRoutes = ["/v1/chat/current/messages": status]
            model.draft = "status \(status)"
            await model.send()
            if [502, 503, 504].contains(status) {
                XCTAssertEqual(model.outbox.last?.state, .waiting, "\(status) means the relay did not reach the Mac")
            } else {
                XCTAssertEqual(model.outbox.last?.isFailed, true, "\(status) came from the Mac")
            }
        }
    }
}
