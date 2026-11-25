import XCTest
@testable import IronPet
@testable import IronPetCore

/// S3 of the send-latency fix: the ack for a phone message does not wait for the work that starts the agent's turn.
@MainActor
final class SendLatencyMacTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var chat: ChatSession!
    private var turns: [ACPTurn] = []
    private var previousBuilder: ((URL, String) -> String?)!

    override func setUp() async throws {
        TestMemory.isolate()
        previousBuilder = ChatSession.preambleBuilder
        chat = ChatSession(restore: false, speech: SpeechPlayer())
        chat.workspace = FileManager.default.temporaryDirectory
        turns = []
        chat.turnRunner = { [unowned self] turn, _ in turns.append(turn) }
        h = RemoteServerHarness(chat: chat)
    }

    override func tearDown() async throws { ChatSession.preambleBuilder = previousBuilder }

    private func elapsed(_ work: () async throws -> Void) async rethrows -> Duration {
        let start = ContinuousClock.now
        try await work()
        return ContinuousClock.now - start
    }

    func testTheAckDoesNotWaitForTheMemoryNotesOfAFirstTurn() async throws {
        // Reading the memory store takes 0.6 s here. On the Mac that work ran before the ack and held it up.
        ChatSession.preambleBuilder = { _, _ in Thread.sleep(forTimeInterval: 0.6); return "NOTES" }
        let remote = RemoteChat(api: h.api, device: "phone", uploads: RemoteUploads(directory: FileManager.default.temporaryDirectory))
        let ledger = RemoteSendLedger()
        var ack: RemoteSendAck?
        let took = try await elapsed { ack = try await remote.send(clientID: UUID().uuidString, ["text": "hello there"], ledger: ledger) }
        print("send-latency recv->ack with a 600 ms memory build: \(took)")
        XCTAssertLessThan(took, .milliseconds(300))
        XCTAssertEqual(ack?.outcome, "sent")
        XCTAssertNotNil(ack?.itemID, "the ack names the user's message")
        XCTAssertTrue(chat.isRunning, "a second message queues behind the turn at once")

        for _ in 0..<200 where turns.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(turns.first?.preamble, "NOTES", "the turn still carries the notes")
        XCTAssertEqual(turns.count, 1)
    }

    func testAStopBeforeTheNotesAreBuiltStartsNoTurn() async throws {
        ChatSession.preambleBuilder = { _, _ in "NOTES" }
        let remote = RemoteChat(api: h.api, device: "phone", uploads: RemoteUploads(directory: FileManager.default.temporaryDirectory))
        _ = try await remote.send(clientID: UUID().uuidString, ["text": "hello there"], ledger: RemoteSendLedger())
        chat.stop()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(turns.isEmpty)
    }
}
