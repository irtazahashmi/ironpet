import XCTest
import IronPetKit
@testable import IronPetRemote

/// The connection state behind the status strip, the full-page error and the reload after a reconnect. A manual sleeper stands in for the
/// clock, so "10 seconds" is something the test decides.
@MainActor
final class NetworkHealthTests: XCTestCase {
    /// Sleeps until the test calls `fire()`.
    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Error>] = []
        /// How many callers are asleep. A sleeper registers on another thread, so a test waits for this before `fire()`.
        var sleepers: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
        var now = Date(timeIntervalSince1970: 1_000_000)

        func sleep(_ duration: Duration) async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); waiting.append(continuation); lock.unlock()
            }
        }

        func fire() {
            lock.lock(); let all = waiting; waiting = []; lock.unlock()
            all.forEach { $0.resume() }
        }
    }

    private func make(_ clock: ManualClock) -> NetworkHealth {
        NetworkHealth(stripDelay: .seconds(10), now: { clock.now }, sleep: { try await clock.sleep($0) })
    }

    // S5: the path coming back reconnects the event socket at once, instead of after its back-off.
    func testThePathReturningReconnectsTheEventSocketNow() {
        let network = make(ManualClock())
        var reconnects = 0
        network.onPathReturned = { reconnects += 1 }
        network.setPath(satisfied: true)
        XCTAssertEqual(reconnects, 0, "a path that never dropped is not a return")
        network.setPath(satisfied: false)
        XCTAssertEqual(reconnects, 0)
        network.setPath(satisfied: true)
        XCTAssertEqual(reconnects, 1)
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    /// Waits until `condition` holds. Work that hops to another thread, such as a timer registering its sleep or a stream handing over
    /// a value, takes longer than a fixed number of yields when the machine is busy, so a test waits for the effect and not for a count.
    private func until(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    // S2
    func testAnOutageUnderTenSecondsShowsNothing() async {
        let clock = ManualClock()
        let network = make(clock)
        network.reportUnreachable()
        XCTAssertNotNil(network.failingSince)
        XCTAssertFalse(network.stripVisible)
        network.reportAnswered()
        await until(clock.sleepers == 1)
        clock.fire()
        await settle()
        XCTAssertFalse(network.stripVisible, "the timer of a short outage does not show the strip when it fires late")
        XCTAssertNil(network.failingSince)
    }

    // S2
    func testALongerOutageShowsTheStripAndTheFirstAnswerHidesIt() async {
        let clock = ManualClock()
        let network = make(clock)
        network.reportUnreachable()
        await until(clock.sleepers == 1)
        clock.fire()
        await until(network.stripVisible)
        XCTAssertTrue(network.stripVisible)
        network.reportAnswered()
        XCTAssertFalse(network.stripVisible)
        XCTAssertNil(network.failingSince)
    }

    func testRepeatedFailuresDoNotRestartTheTenSeconds() async {
        let clock = ManualClock()
        let network = make(clock)
        network.reportUnreachable()
        let first = network.failingSince
        clock.now.addTimeInterval(6)
        network.report(ClientError.transport("x"))
        XCTAssertEqual(network.failingSince, first)
    }

    func testAnErrorFromTheMacCountsAsAnAnswer() {
        let network = make(ManualClock())
        network.reportUnreachable()
        network.report(ClientError.api(status: 500, code: "failed", message: "x"))
        XCTAssertNil(network.failingSince, "the Mac answered, so it is reachable")
    }

    func testTheWordingFollowsThePhoneNetwork() {
        let network = make(ManualClock())
        XCTAssertEqual(network.stripTitle, "Can't reach your Mac")
        network.setPath(satisfied: false)
        XCTAssertEqual(network.stripTitle, "Offline, changes will sync")
        network.setPath(satisfied: true)
        XCTAssertEqual(network.stripTitle, "Can't reach your Mac")
    }

    func testTheStripSaysHowOldTheLastDataIs() {
        let clock = ManualClock()
        let network = make(clock)
        XCTAssertNil(network.updatedText())
        network.reportAnswered()
        clock.now.addTimeInterval(5 * 60 + 10)
        XCTAssertEqual(network.updatedText(), "Updated 5 min ago")
        clock.now.addTimeInterval(2 * 3600)
        XCTAssertEqual(network.updatedText(), "Updated 2 h ago")
    }

    // S3
    func testEveryStartedScreenReadsAgainWhenTheConnectionReturns() async {
        let clock = ManualClock()
        let network = make(clock)
        var firstGot = 0, secondGot = 0
        let first = network.reconnects(), second = network.reconnects()
        let a = Task { for await _ in first { firstGot += 1 } }
        let b = Task { for await _ in second { secondGot += 1 } }
        await settle()
        network.reportAnswered()
        XCTAssertEqual(firstGot + secondGot, 0, "an answer while nothing was down is no reconnect")
        network.reportUnreachable()
        network.reportAnswered()
        await until(firstGot == 1 && secondGot == 1)
        await settle()
        XCTAssertEqual(firstGot, 1)
        XCTAssertEqual(secondGot, 1)
        a.cancel(); b.cancel()
    }

    func testTheNetworkReturningAnnouncesAReconnect() async {
        let network = make(ManualClock())
        var got = 0
        let stream = network.reconnects()
        let task = Task { for await _ in stream { got += 1 } }
        network.setPath(satisfied: false)
        network.setPath(satisfied: true)
        await until(got == 1)
        await settle()
        XCTAssertEqual(got, 1)
        task.cancel()
    }

    func testAProblemShowsOncePerLaunch() {
        let network = make(ManualClock())
        network.raise(.macTooOld)
        XCTAssertEqual(network.problem, .macTooOld)
        network.problem = nil
        network.raise(.macTooOld)
        XCTAssertNil(network.problem, "the sheet does not come back after every failed read")
    }
}
