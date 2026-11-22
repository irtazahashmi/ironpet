import XCTest
import IronPetKit
@testable import IronPetRemote

/// S1, S2 and S3 of the send-latency fix: a sent message shows at once, reconciles with the Mac's copy, and fails with a Retry.
@MainActor
final class SendLatencyTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func started() async -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.start()
        await poll { model.loaded && model.snapshot != nil }
        return model
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func count(_ text: String, in model: ChatModel) -> Int { model.displayItems.filter { $0.text == text }.count }

    // S1
    func testASentMessageShowsAtOnceWithTheTypingRowBeforeTheMacAnswers() async {
        let model = await started()
        server.sendDelay = 1.0
        model.draft = "hello"
        let start = ContinuousClock.now
        let sending = Task { await model.send() }
        await poll(1) { self.count("hello", in: model) == 1 }
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(count("hello", in: model), 1)
        XCTAssertLessThan(elapsed, .milliseconds(100), "the message is drawn before any network answer")
        XCTAssertTrue(model.awaitingReply, "the typing row shows at once")
        XCTAssertEqual(model.outbox.first?.state, .sending)
        XCTAssertEqual(model.draft, "")
        await sending.value
        model.stop()
    }

    // S2
    func testTheMacsCopyReplacesTheLocalOneOnce() async {
        let model = await started()
        model.draft = "once"
        await model.send()
        await poll { model.items.contains { $0.text == "once" } }
        XCTAssertEqual(count("once", in: model), 1)
        XCTAssertTrue(model.outbox.isEmpty)
        model.stop()
    }

    func testAPushedItemThatArrivesBeforeTheAnswerDoesNotDuplicate() async {
        let model = await started()
        server.sendDelay = 0.6
        server.sendPushesFirst = true
        model.draft = "early"
        let sending = Task { await model.send() }
        await poll { model.items.contains { $0.text == "early" } }
        XCTAssertEqual(count("early", in: model), 1, "the pushed copy settles the local one before the send answers")
        XCTAssertTrue(model.outbox.isEmpty)
        await sending.value
        XCTAssertEqual(count("early", in: model), 1)
        model.stop()
    }

    func testTwoIdenticalMessagesStayTwo() async {
        let model = await started()
        model.draft = "again"
        await model.send()
        server.chat.running = false
        model.draft = "again"
        await model.send()
        await poll { model.items.filter { $0.text == "again" }.count == 2 }
        XCTAssertEqual(count("again", in: model), 2)
        XCTAssertTrue(model.outbox.isEmpty)
        model.stop()
    }

    // S3
    func testAFailedSendStaysInTheTranscriptAndRetrySendsItOnce() async throws {
        let model = await started()
        server.sendFails = true
        model.draft = "oops"
        await model.send()
        XCTAssertEqual(count("oops", in: model), 1)
        let failed = try XCTUnwrap(model.outbox.first)
        guard case .failed(let reason) = failed.state else { return XCTFail("expected a failed message, got \(failed.state)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(model.awaitingReply, "no typing row for a message that did not go")
        server.sendFails = false
        async let first: Void = model.retry(failed.id)
        async let second: Void = model.retry(failed.id)
        _ = await (first, second)
        XCTAssertEqual(server.count("POST /v1/chat/current/messages"), 2, "one failed send and one retry")
        await poll { model.items.contains { $0.text == "oops" } }
        XCTAssertEqual(count("oops", in: model), 1)
        XCTAssertTrue(model.outbox.isEmpty)
        model.stop()
    }

    func testAnUnansweredSendFailsAfterTheTimeout() async {
        let model = await started()
        model.sendTimeout = .milliseconds(150)
        server.sendDelay = 1.5
        model.draft = "slow"
        await model.send()
        XCTAssertTrue(model.outbox.first?.isFailed ?? false)
        model.stop()
    }

    func testAFailedAttachmentOnlySendGivesTheAttachmentBack() async {
        let model = await started()
        server.sendFails = true
        model.attach(data: Data("x".utf8), fileName: "a.txt", contentType: "text/plain")
        await model.send()
        XCTAssertEqual(model.attachments.count, 1, "nothing local to retry, so the composer gets it back")
        XCTAssertTrue(model.outbox.isEmpty)
        model.stop()
    }
}
