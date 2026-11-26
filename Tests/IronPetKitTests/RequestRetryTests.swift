import XCTest
@testable import IronPetKit

final class RequestRetryTests: XCTestCase {
    private actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    func testTheWaitDoublesAndStopsAtTheCap() {
        let policy = RetryPolicy(attempts: 6, base: .seconds(1), maxDelay: .seconds(5))
        XCTAssertEqual(policy.delay(afterAttempt: 1), .seconds(1))
        XCTAssertEqual(policy.delay(afterAttempt: 2), .seconds(2))
        XCTAssertEqual(policy.delay(afterAttempt: 3), .seconds(4))
        XCTAssertEqual(policy.delay(afterAttempt: 4), .seconds(5))
        XCTAssertEqual(policy.delay(afterAttempt: 40), .seconds(5))
    }

    func testAnUnreachableMacIsRetriedUntilItAnswers() async throws {
        let counter = Counter()
        let waits = WaitLog()
        let value: Int = try await RequestRetry.perform(RetryPolicy(attempts: 3, base: .seconds(1)), sleep: { await waits.add($0) }) {
            if await counter.next() < 3 { throw ClientError.transport("The request timed out.") }
            return 7
        }
        XCTAssertEqual(value, 7)
        let seen = await waits.all
        XCTAssertEqual(seen, [.seconds(1), .seconds(2)])
    }

    // S4: a timed-out big read is not retried when the caller says so, and a small request still is.
    func testATimedOutReadIsNotRetriedWhenTheCallerSaysSo() async {
        let counter = Counter()
        do {
            _ = try await RequestRetry.perform(RetryPolicy(attempts: 3, base: .milliseconds(1)), sleep: { _ in }, retriesTimeouts: false) { () async throws -> Int in
                _ = await counter.next()
                throw ClientError.timedOut
            }
            XCTFail("should throw")
        } catch { XCTAssertEqual(error as? ClientError, .timedOut) }
        let tries = await counter.value
        XCTAssertEqual(tries, 1)
    }

    func testATimeoutIsRetriedByDefaultAndOtherNetworkErrorsStillAreWithoutRetryingTimeouts() async throws {
        let timeouts = Counter()
        let value: Int = try await RequestRetry.perform(RetryPolicy(attempts: 3, base: .milliseconds(1)), sleep: { _ in }) {
            if await timeouts.next() < 3 { throw ClientError.timedOut }
            return 1
        }
        XCTAssertEqual(value, 1)
        let drops = Counter()
        let again: Int = try await RequestRetry.perform(RetryPolicy(attempts: 3, base: .milliseconds(1)), sleep: { _ in }, retriesTimeouts: false) {
            if await drops.next() < 3 { throw ClientError.transport("The network connection was lost.") }
            return 2
        }
        XCTAssertEqual(again, 2, "a dropped connection is transient even where timeouts are not retried")
    }

    func testTheLastFailureIsThrownAfterTheLastTry() async {
        let counter = Counter()
        do {
            _ = try await RequestRetry.perform(RetryPolicy(attempts: 3, base: .milliseconds(1)), sleep: { _ in }) { () async throws -> Int in
                _ = await counter.next()
                throw URLError(.timedOut)
            }
            XCTFail("should throw")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let tries = await counter.value
        XCTAssertEqual(tries, 3)
    }

    func testAnAnswerFromTheMacIsNeverRetried() async {
        let counter = Counter()
        for failure: Error in [ClientError.unauthorized, ClientError.api(status: 404, code: "not_found", message: "no"), ClientError.api(status: 500, code: "failed", message: "no"), ClientError.invalidResponse] {
            do {
                _ = try await RequestRetry.perform(sleep: { _ in }) { () async throws -> Int in _ = await counter.next(); throw failure }
                XCTFail("should throw")
            } catch {}
        }
        let tries = await counter.value
        XCTAssertEqual(tries, 4, "one try for each of the four failures")
    }

    func testAGatewayErrorIsRetried() {
        XCTAssertTrue(RequestRetry.isTransient(ClientError.api(status: 503, code: "x", message: "x")))
        XCTAssertFalse(RequestRetry.isTransient(URLError(.cancelled)))
        XCTAssertFalse(RequestRetry.isTransient(CancellationError()))
    }

    func testNoTransportWordingReachesAUserFacingDescription() {
        XCTAssertEqual(ClientError.transport("The request timed out.").errorDescription, "Can't reach your Mac.")
    }
}

private actor WaitLog {
    var all: [Duration] = []
    func add(_ wait: Duration) { all.append(wait) }
}
