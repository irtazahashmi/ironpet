import IronPetKit
import XCTest
@testable import IronPet
@testable import IronPetCore

/// Keeps the resume point in memory, as the phone keeps it in `UserDefaults`.
private final class MemoryResumeStore: EventResumeStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: (seq: Int, epoch: String?)?
    init(_ saved: (seq: Int, epoch: String?)? = nil) { self.saved = saved }
    func load() -> (seq: Int, epoch: String?)? { lock.lock(); defer { lock.unlock() }; return saved }
    func save(seq: Int, epoch: String?) { lock.lock(); saved = (seq, epoch); lock.unlock() }
}

private final class CapturedLog: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func note(category: String, _ message: String) { lock.lock(); if category == "remote-resume" { lines.append(message) }; lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// A phone that reconnects sends the last `seq` it applied. The phone side is the real `EventConnection`, the Mac side the real listener.
@MainActor
final class RemoteResumeTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var client: IronPetClient!
    private var log: CapturedLog!
    private var previousSink: LogSink!

    override func setUp() async throws {
        TestMemory.isolate()
        h = RemoteServerHarness(chat: ChatSession(restore: false, speech: SpeechPlayer()))
        try await h.start()
        let token = try await h.pairDevice().token
        client = IronPetClient(endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(h.port)")!), token: token)
        previousSink = Log.fallbackSink
        log = CapturedLog()
        Log.fallbackSink = log
    }

    override func tearDown() async throws {
        Log.fallbackSink = previousSink
        await h.stop()
    }

    /// Reads the connection's signals until `done` says the list is complete, or two seconds pass.
    private func collect(_ connection: EventConnection, until done: @escaping @MainActor ([EventSignal]) -> Bool) async -> [EventSignal] {
        var seen: [EventSignal] = []
        let stream = connection.signals()
        let reading = Task { @MainActor in
            for await signal in stream {
                seen.append(signal)
                if done(seen) { break }
            }
        }
        let stopper = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); reading.cancel() }
        await reading.value
        stopper.cancel()
        return seen
    }

    private func seqs(_ signals: [EventSignal]) -> [Int] {
        signals.compactMap { if case .event(let event) = $0 { event.seq } else { nil } }
    }

    // S1
    func testAReconnectReplaysExactlyTheMissedEventsInOrderAndNothingElse() async throws {
        let store = MemoryResumeStore()
        let first = EventConnection(client: client, store: store)
        for _ in 0..<3 { h.events.publish(.tasksChanged) }
        // The first connection applies the 3 events that exist, then the socket drops.
        let before = await collect(first, until: { _ in first.lastSeq == self.h.events.lastSeq && first.lastSeq != nil })
        XCTAssertEqual(before.first, .connected, "a first connection reads everything once")
        // The connection saves on a queue of its own, so the write may land a moment after the last event.
        for _ in 0..<100 where store.load()?.seq != h.events.lastSeq { try await Task.sleep(nanoseconds: 20_000_000) }
        let applied = try XCTUnwrap(store.load()).seq
        XCTAssertEqual(applied, h.events.lastSeq)
        XCTAssertEqual(store.load()?.epoch, h.events.epoch)

        let missedKinds: [APIEventKind] = [.tasksChanged, .agentsChanged, .alertsChanged, .meetingsChanged]
        for kind in missedKinds { h.events.publish(kind) }

        // A new connection is the phone after the drop, with only the stored resume point.
        let second = EventConnection(client: client, store: store)
        let signals = await collect(second, until: { $0.contains { if case .resumed = $0 { true } else { false } } })
        XCTAssertEqual(seqs(signals), Array((applied + 1)...(applied + 4)), "each missed event once, in order")
        XCTAssertEqual(signals.last, .resumed(replayed: 4))
        XCTAssertFalse(signals.contains(.connected), "no full refetch")
        XCTAssertFalse(signals.contains(.resync), "no full refetch")
        for _ in 0..<100 where store.load()?.seq != h.events.lastSeq { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.load()?.seq, h.events.lastSeq)
        XCTAssertTrue(log.all.contains("events resume_from=\(applied) replayed=4"), "\(log.all)")
    }

    func testAnEventAfterTheResumeArrivesOnceAfterTheReplay() async throws {
        let store = MemoryResumeStore((seq: h.events.lastSeq, epoch: h.events.epoch))
        let connection = EventConnection(client: client, store: store)
        let start = h.events.lastSeq
        h.events.publish(.tasksChanged)
        let stream = connection.signals()
        var seen: [EventSignal] = []
        let reading = Task { @MainActor in
            for await signal in stream {
                seen.append(signal)
                if seqs(seen).count == 2 { break }
            }
        }
        for _ in 0..<100 where !seen.contains(.resumed(replayed: 1)) { try await Task.sleep(nanoseconds: 20_000_000) }
        h.events.publish(.agentsChanged)
        // A Mac that never sends the second event must fail the test, not hang it.
        let stopper = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); reading.cancel() }
        await reading.value
        stopper.cancel()
        XCTAssertEqual(seqs(seen), [start + 1, start + 2])
        XCTAssertEqual(seen.firstIndex(of: .resumed(replayed: 1)), 1, "the replay, then resumed, then live events")
    }

    // S2
    func testASeqOutsideTheBufferGetsOneResyncAndNoEvents() async throws {
        // 600 events push the first 100 out of the 500-entry buffer.
        for _ in 0..<600 { h.events.publish(.tasksChanged) }
        let store = MemoryResumeStore((seq: 1, epoch: h.events.epoch))
        let connection = EventConnection(client: client, store: store)
        let signals = await collect(connection, until: { $0.contains(.resync) })
        XCTAssertEqual(signals, [.resync])
        for _ in 0..<100 where store.load()?.seq != h.events.lastSeq { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.load()?.seq, h.events.lastSeq, "the phone continues from where the Mac is now")
        XCTAssertTrue(log.all.contains("events resume_from=1 too_old=true"), "\(log.all)")
    }

    func testASeqFromAnEarlierLaunchOfTheMacGetsAResyncEvenWhenTheNumberFits() async throws {
        for _ in 0..<5 { h.events.publish(.tasksChanged) }
        let store = MemoryResumeStore((seq: 2, epoch: "another-launch"))
        let connection = EventConnection(client: client, store: store)
        let signals = await collect(connection, until: { $0.contains(.resync) })
        XCTAssertEqual(signals, [.resync])
        for _ in 0..<100 where store.load()?.epoch != h.events.epoch { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.load()?.epoch, h.events.epoch)
    }

    func testAPhoneWithoutASavedSeqReadsEverythingOnce() async throws {
        let connection = EventConnection(client: client, store: MemoryResumeStore())
        let signals = await collect(connection, until: { !$0.isEmpty })
        XCTAssertEqual(signals, [.connected])
    }
}
