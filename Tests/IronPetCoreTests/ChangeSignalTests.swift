import XCTest
#if canImport(Combine)
import Combine
#endif
@testable import IronPetCore

@MainActor
final class ChangeSignalTests: XCTestCase {
    // S1
    func testEveryObserverRunsOncePerSend() async {
        let signal = ChangeSignal()
        var first = 0, second = 0
        let a = signal.observe { first += 1 }
        let b = signal.observe { second += 1 }
        signal.send()
        XCTAssertEqual([first, second], [1, 1])
        signal.send()
        XCTAssertEqual([first, second], [2, 2])
        withExtendedLifetime([a, b]) {}
    }

    // S1
    func testAReleasedOrCancelledTokenStopsItsHandler() async {
        let signal = ChangeSignal()
        var kept = 0, cancelled = 0, released = 0
        let keep = signal.observe { kept += 1 }
        let cancel = signal.observe { cancelled += 1 }
        var drop: ChangeToken? = signal.observe { released += 1 }
        cancel.cancel()
        drop = nil
        signal.send()
        XCTAssertEqual([kept, cancelled, released], [1, 0, 0])
        withExtendedLifetime((keep, drop)) {}
    }

    // S1
    func testAHandlerCancelledByAnEarlierHandlerDoesNotRun() async {
        let signal = ChangeSignal()
        var later = 0
        var laterToken: ChangeToken?
        let first = signal.observe { laterToken?.cancel() }
        laterToken = signal.observe { later += 1 }
        signal.send()
        XCTAssertEqual(later, 0)
        withExtendedLifetime(first) {}
    }

    // S1
    func testAStreamGetsOneElementPerSendAndFinishesWhenTheSignalGoesAway() async {
        var signal: ChangeSignal? = ChangeSignal()
        let stream = signal!.stream()
        signal!.send()
        signal!.send()
        signal!.send()
        signal = nil
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 3, "buffered sends arrive, then the stream ends")
    }

    // S1
    func testACancelledConsumerEndsItsStreamAndTheSignalKeepsWorking() async {
        let signal = ChangeSignal()
        let stream = signal.stream()
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        signal.send()
        await Task.yield()
        consumer.cancel()
        _ = await consumer.value
        var seen = 0
        let token = signal.observe { seen += 1 }
        signal.send()
        XCTAssertEqual(seen, 1)
        withExtendedLifetime(token) {}
    }

    #if canImport(Combine)
    // S2
    func testTheCombinePublisherFiresBeforeTheObserveHandlers() async {
        let signal = ChangeSignal()
        var order: [String] = []
        let token = signal.observe { order.append("observe") }
        let subscription = signal.objectWillChange.sink { order.append("objectWillChange") }
        signal.send()
        XCTAssertEqual(order, ["objectWillChange", "observe"])
        withExtendedLifetime((token, subscription)) {}
    }
    #endif
}
