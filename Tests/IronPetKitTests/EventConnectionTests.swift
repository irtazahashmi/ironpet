import XCTest
@testable import IronPetKit

final class EventConnectionTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    func connection(token: String? = nil) -> EventConnection {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: token ?? server.token)
        return EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))
    }

    func next(_ iterator: inout AsyncStream<EventSignal>.Iterator) async -> EventSignal? {
        await withTaskGroup(of: EventSignal?.self) { [iterator] group in
            var copy = iterator
            group.addTask { await copy.next() }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func testDeliversEventsAndReconnectsWithTheLastSeq() async throws {
        let events = connection()
        let received = LockedBox<[EventSignal]>([])
        let task = Task { for await signal in events.signals() { received.mutate { $0.append(signal) } } }
        defer { task.cancel() }

        try await wait { received.value.contains(.connected) }
        let seq = server.publish("tasks.changed", id: "t1")
        try await wait { received.value.contains { if case .event(let e) = $0 { return e.seq == seq } else { return false } } }
        XCTAssertEqual(events.lastSeq, seq)

        server.dropSockets()
        // Published while the phone is away: replayed on the next connect.
        let missed = server.publish("tasks.changed", id: "t2")
        try await wait { self.server.socketURLs.count == 2 }
        XCTAssertEqual(server.socketURLs.last, "/v1/events?since=\(seq)")
        try await wait { received.value.contains { if case .event(let e) = $0 { return e.seq == missed } else { return false } } }
    }

    func testResyncResetsTheSeq() async throws {
        let events = connection()
        let received = LockedBox<[EventSignal]>([])
        let task = Task { for await signal in events.signals() { received.mutate { $0.append(signal) } } }
        defer { task.cancel() }
        try await wait { received.value.contains(.connected) }
        server.publish("tasks.changed")
        server.gapOnNextConnect = true
        server.dropSockets()
        try await wait { received.value.contains(.resync) }
    }

    func testUnauthorizedEndsTheStream() async throws {
        server.tokenValid = false
        var iterator = connection().signals().makeAsyncIterator()
        let signal = await next(&iterator)
        XCTAssertEqual(signal, .unauthorized)
    }

    func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out")
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ change: (inout T) -> Void) { lock.lock(); change(&_value); lock.unlock() }
}
