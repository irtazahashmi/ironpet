import XCTest
import IronPetKit
@testable import IronPetRemote

/// A failed background read goes through the shared retry policy. Nothing on the chat screen retries or shows an error of its own: the
/// connection state lives in `NetworkHealth`, which shows the strip after a sustained outage and clears when the Mac answers.
@MainActor
final class ChatConnectionTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func started(network: NetworkHealth? = nil) async -> ChatModel {
        let network = network ?? NetworkHealth()
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        network.retryPolicy = RetryPolicy(attempts: 3, base: .milliseconds(30), maxDelay: .milliseconds(120))
        let model = ChatModel(client: client, events: events, network: network, onUnauthorized: {})
        model.start()
        await poll { model.loaded && model.snapshot != nil }
        // The socket's own connect refresh can still be in flight and would take the failure a test arms next. The socket opens
        // after the first read, sometimes long after on a slow runner, so wait for it to open before the reads settle.
        await poll { !server.socketURLs.isEmpty }
        try? await Task.sleep(nanoseconds: 500_000_000)
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

    // S3
    func testOneFailedReadIsRetriedAndNothingShows() async {
        let network = NetworkHealth()
        let model = await started(network: network)
        server.chat.title = "After the retry"
        server.chatReadFailures = 1
        await model.refresh()
        XCTAssertEqual(model.title, "After the retry", "the shared client read again after the first failure")
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(network.failingSince, "one retried timeout is never reported")
        XCTAssertFalse(network.stripVisible)
        model.stop()
    }

    // S2
    func testASustainedOutageShowsTheStripAndClearsWhenTheMacAnswers() async {
        let network = NetworkHealth(stripDelay: .milliseconds(200))
        let model = await started(network: network)
        server.chatReadFailures = Int.max
        await model.refresh()
        XCTAssertNotNil(network.failingSince)
        XCTAssertFalse(network.stripVisible, "a short outage shows nothing")
        await poll { network.stripVisible }
        XCTAssertTrue(network.stripVisible)
        XCTAssertNil(model.errorMessage, "the strip is the only place the outage shows")
        server.chatReadFailures = 0
        await model.refresh()
        XCTAssertFalse(network.stripVisible, "the strip hides with the first answer")
        XCTAssertNotNil(network.lastSync)
        model.stop()
    }

    // S3
    func testTheScreenReadsAgainWhenTheConnectionComesBack() async {
        let network = NetworkHealth()
        let model = await started(network: network)
        server.chatReadFailures = Int.max
        await model.refresh()
        XCTAssertNotNil(network.failingSince)
        server.chat.title = "Back again"
        server.chatReadFailures = 0
        // Any answer from the Mac, here a read of another screen, announces the reconnect, and the started screen reads without being asked.
        network.reportAnswered()
        await poll { model.title == "Back again" }
        XCTAssertEqual(model.title, "Back again")
        model.stop()
    }

    func testAReadIsTriedAtMostOncePerAttemptOfThePolicy() async {
        let model = await started()
        server.chatReadFailures = Int.max
        let before = server.count("GET /v1/chat/current")
        await model.refresh()
        XCTAssertEqual(server.count("GET /v1/chat/current") - before, 3, "three tries, then the failure is reported once")
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
        model.stop()
    }

    // S4
    func testNoURLSessionWordingReachesTheUser() {
        XCTAssertEqual(PlainError.message(for: URLError(.timedOut)), "Can't reach your Mac.")
        XCTAssertEqual(PlainError.message(for: ClientError.transport("The request timed out.")), "Can't reach your Mac.")
        XCTAssertEqual(PlainError.message(for: ClientError.api(status: 409, code: "busy", message: "A turn is running.")), "A turn is running.")
        XCTAssertEqual(PlainError.message(for: NSError(domain: "x", code: 1)), "Something went wrong. Try again.")
    }

    func testAFailedUserActionReportsToTheStripAndShowsNoRow() async {
        let network = NetworkHealth()
        let model = await started(network: network)
        server.stop()
        await model.stopTurn()
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(network.failingSince)
        model.stop()
    }
}
