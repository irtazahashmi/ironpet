import XCTest
import IronPetKit
@testable import IronPetRemote

/// A streamed reply grows on the phone as it grows on the Mac, with the text in the event or, from an older Mac, through coalesced reads.
@MainActor
final class StreamingTests: XCTestCase {
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

    private func text(_ model: ChatModel) -> String? { model.items.first { $0.id == "reply" }?.text }

    /// Streams `chunks` words, `gap` seconds apart, and returns each distinct text of the reply the model showed on the way.
    private func stream(into model: ChatModel, chunks: Int, gap: Double) async -> (seen: [String], full: String) {
        var seen: [String] = []
        var full = ""
        for n in 1...chunks {
            let word = "w\(n) "
            full += word
            server.streamChunk(item: "reply", word)
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            if let current = text(model), seen.last != current { seen.append(current) }
        }
        return (seen, full)
    }

    // S1
    func testTheTextInTheEventShowsWithoutAnyRead() async {
        let model = await started()
        let result = await stream(into: model, chunks: 30, gap: 0.03)
        await poll { self.text(model) == result.full }
        XCTAssertEqual(text(model), result.full)
        XCTAssertGreaterThanOrEqual(result.seen.count, 10, "the reply grew in many steps")
        XCTAssertEqual(server.messageReads, 0, "the event carried the text")
        model.stop()
    }

    // S2
    func testBurstsOfEventsKeepOneReadPerMessageInFlightAndTheLastTextWins() async {
        let model = await started()
        server.legacyEvents = true
        server.messageReadDelay = 0.25
        let result = await stream(into: model, chunks: 30, gap: 0.02)
        await poll { self.text(model) == result.full }
        XCTAssertEqual(text(model), result.full, "no stale read overwrote a newer one")
        XCTAssertEqual(server.maxMessageReadsInFlight, 1)
        XCTAssertLessThan(server.messageReads, 10, "events during a read share the next one")
        model.stop()
    }

    // S3
    func testAnOlderMacWithoutTextInTheEventStillStreamsAndEndsWithTheFullText() async {
        let model = await started()
        server.legacyEvents = true
        server.messageReadDelay = 0.05
        let result = await stream(into: model, chunks: 30, gap: 0.03)
        server.finishTurn()
        await poll { self.text(model) == result.full && !model.running }
        XCTAssertEqual(text(model), result.full)
        XCTAssertGreaterThan(server.messageReads, 0, "without text in the event the phone reads the message")
        model.stop()
    }

    func testAnEventWhoseItemTheAppCannotReadFallsBackToARead() throws {
        let json = #"{"seq":3,"kind":"chat.item","id":"a","item":{"id":"a","kind":["bad"]}}"#
        let event = try JSONDecoder().decode(RemoteEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.id, "a")
        XCTAssertNil(event.item)
        let plain = try JSONDecoder().decode(RemoteEvent.self, from: Data(#"{"seq":4,"kind":"chat.item","id":"a"}"#.utf8))
        XCTAssertNil(plain.item)
    }

    /// Milliseconds from the Mac's last chunk until the phone shows the whole reply, over a route where each read takes `readDelay`.
    private func lagAfterLastChunk(legacy: Bool, readDelay: Double) async -> Double {
        let model = await started()
        server.legacyEvents = legacy
        server.messageReadDelay = readDelay
        var full = ""
        for n in 1...30 {
            full += "w\(n) "
            server.streamChunk(item: "reply", "w\(n) ")
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let start = ContinuousClock.now
        await poll { self.text(model) == full }
        model.stop()
        return Double((ContinuousClock.now - start).components.attoseconds) / 1e15
    }

    // S5: the lag after the last chunk, with a 300 ms read, as over the tunnel. Printed for the PR.
    func testTheReplyCatchesUpFasterWithTheTextInTheEvent() async {
        let before = await lagAfterLastChunk(legacy: true, readDelay: 0.3)
        server.stop()
        server = MockIronPetServer()
        try? server.start()
        let after = await lagAfterLastChunk(legacy: false, readDelay: 0.3)
        print("STREAM-LAG legacy_ms=\(Int(before)) inline_ms=\(Int(after))")
        XCTAssertLessThan(after, before, "the text in the event removes the wait for the last read")
    }
}
