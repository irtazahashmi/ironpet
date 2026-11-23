import XCTest
import IronPetKit
@testable import IronPetRemote

/// A failed background read retries quietly. Only a run of failures shows one plain banner, and it clears when the Mac answers.
@MainActor
final class ChatConnectionTests: XCTestCase {
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
        model.retryBase = .milliseconds(30)
        model.start()
        await poll { model.loaded && model.snapshot != nil }
        // The socket's own connect refresh can still be in flight and would take the failure a test arms next.
        var seen = -1
        while seen != server.count("GET /v1/chat/current") {
            seen = server.count("GET /v1/chat/current")
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return model
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // S1
    func testOneFailedRefreshShowsNoBannerAndTheRetrySucceeds() async {
        let model = await started()
        model.retryBase = .milliseconds(400)
        server.chat.title = "After the retry"
        server.chatReadFailures = 1
        await model.refresh()
        XCTAssertNotEqual(model.title, "After the retry", "the first read failed")
        XCTAssertFalse(model.connectionLost)
        XCTAssertNil(model.errorMessage)
        await poll { model.title == "After the retry" }
        XCTAssertEqual(model.title, "After the retry", "the quiet retry read the chat again")
        XCTAssertFalse(model.connectionLost)
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    // S2
    func testASustainedOutageShowsOneBannerThatClearsByItself() async {
        let model = await started()
        server.chatReadFailures = Int.max
        await model.refresh()
        XCTAssertFalse(model.connectionLost, "one failure is not an outage")
        await poll { model.connectionLost }
        XCTAssertTrue(model.connectionLost)
        XCTAssertNil(model.errorMessage, "the banner is the only message")
        server.chatReadFailures = 0
        await poll { !model.connectionLost }
        XCTAssertFalse(model.connectionLost, "the banner goes once the Mac answers")
        model.stop()
    }

    func testRetriesDoNotPileUp() async {
        let model = await started()
        model.retryBase = .seconds(60)
        server.chatReadFailures = Int.max
        for _ in 0..<5 { await model.refresh() }
        let settled = server.count("GET /v1/chat/current")
        await poll(0.4) { false }
        XCTAssertEqual(server.count("GET /v1/chat/current"), settled, "five failures wait on one retry, which has not fired")
        model.stop()
    }

    func testTheRetryButtonReadsAtOnce() async {
        let model = await started()
        model.retryBase = .seconds(60)
        server.chatReadFailures = Int.max
        for _ in 0..<3 { await model.refresh() }
        XCTAssertTrue(model.connectionLost)
        server.chatReadFailures = 0
        await model.retryNow()
        XCTAssertFalse(model.connectionLost)
        model.stop()
    }

    // S3
    func testAFailedSendHasNoBanner() async {
        let model = await started()
        server.sendFails = true
        model.draft = "oops"
        await model.send()
        XCTAssertTrue(model.outbox.first?.isFailed ?? false)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.connectionLost)
        model.stop()
    }

    // S4
    func testNoURLSessionWordingReachesTheUser() {
        XCTAssertEqual(PlainError.message(for: URLError(.timedOut)), "Can't reach your Mac.")
        XCTAssertEqual(PlainError.message(for: ClientError.transport("The request timed out.")), "Can't reach your Mac.")
        XCTAssertEqual(PlainError.message(for: ClientError.api(status: 409, code: "busy", message: "A turn is running.")), "A turn is running.")
        XCTAssertEqual(PlainError.message(for: NSError(domain: "x", code: 1)), "Something went wrong. Try again.")
    }

    func testAFailedUserActionKeepsAPlainMessage() async {
        let model = await started()
        server.stop()
        await model.stopTurn()
        XCTAssertEqual(model.errorMessage, "Can't reach your Mac.")
        model.stop()
    }
}
