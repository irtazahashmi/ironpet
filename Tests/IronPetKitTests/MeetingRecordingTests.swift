import XCTest
@testable import IronPetKit

/// A Mac that keeps the chunks it was sent by index, can be away, and can lose a chosen answer after it stored the chunk.
private final class ChunkMac: MeetingRecordingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var chunks: [Int: Data] = [:]
    /// Every chunk request that reached the Mac, in order.
    private(set) var arrivals: [Int] = []
    private(set) var completions: [(count: Int, startedAt: Date)] = []
    var reachable = true
    /// Requests that fail before the Mac sees them.
    var failNext = 0
    /// The Mac stores the chunk but the answer never arrives.
    var loseAnswerForIndex: Int?
    var refuseWith: String?

    func sendRecordingChunk(id: String, index: Int, data: Data) async throws {
        try lock.withLock {
            guard reachable else { throw ClientError.transport("offline") }
            if failNext > 0 { failNext -= 1; throw ClientError.timedOut }
            if let refuseWith { throw ClientError.api(status: 400, code: "invalid", message: refuseWith) }
            arrivals.append(index)
            if chunks[index] == nil { chunks[index] = data }
            if loseAnswerForIndex == index { loseAnswerForIndex = nil; throw ClientError.timedOut }
        }
    }

    func completeRecording(id: String, count: Int, startedAt: Date) async throws {
        try lock.withLock {
            guard reachable else { throw ClientError.transport("offline") }
            let missing = (0..<count).filter { chunks[$0] == nil }
            guard missing.isEmpty else { throw ClientError.api(status: 409, code: "conflict", message: "missing \(missing)") }
            completions.append((count, startedAt))
        }
    }
}

final class MeetingRecordingTests: XCTestCase {
    private var dir: URL!
    private var queue: MeetingRecordingQueue!
    private let started = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-recording-\(UUID().uuidString)")
        queue = MeetingRecordingQueue(folder: dir, now: { [started] in started })
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func wav(_ marker: UInt8) -> Data { MeetingRecordingFormat.wav(pcm: Data(repeating: marker, count: 64)) }

    private func record(_ chunks: Int, stop: Bool = true) throws -> PendingRecording {
        let recording = try queue.begin()
        for index in 0..<chunks { try queue.append(recording.id, wav: wav(UInt8(index))) }
        if stop { queue.stop(recording.id) }
        return recording
    }

    // S1
    func testARecordingGoesToTheMacChunkByChunkAndIsCompletedOnce() async throws {
        let mac = ChunkMac()
        let recording = try record(3)
        let completed = await queue.drain(using: mac)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(mac.arrivals, [0, 1, 2])
        XCTAssertEqual(mac.completions.map(\.count), [3])
        XCTAssertEqual(mac.completions.first?.startedAt, started)
        XCTAssertEqual(mac.chunks[1], wav(1))
        XCTAssertEqual(queue.pending, [], "nothing waits once the Mac completed it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(recording.id).path))
    }

    // S3
    func testAChunkThatFailsStaysOnDiskAndTheMacEndsWithEveryChunkOnceInOrder() async throws {
        let mac = ChunkMac()
        let recording = try record(4)
        mac.loseAnswerForIndex = 1
        mac.failNext = 0
        var completed = await queue.drain(using: mac)
        XCTAssertEqual(completed, 0, "the answer for chunk 1 was lost, so the run stops there")
        XCTAssertEqual(queue.unconfirmed(recording.id), [1, 2, 3], "chunk 0 is confirmed and deleted, the failed chunk and the rest stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.chunkURL(recording: recording.id, index: 1).path))
        XCTAssertTrue(mac.completions.isEmpty)
        completed = await queue.drain(using: mac)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(mac.chunks.keys.sorted(), [0, 1, 2, 3])
        XCTAssertEqual(mac.chunks.mapValues { $0 }, [0: wav(0), 1: wav(1), 2: wav(2), 3: wav(3)], "each index holds its own audio, once")
        XCTAssertEqual(mac.arrivals, [0, 1, 1, 2, 3], "only the chunk whose answer was lost is sent twice, and the Mac keeps one copy")
        XCTAssertEqual(mac.completions.map(\.count), [4])
    }

    // S3
    func testATransientFailureBeforeTheMacSeesTheChunkIsRetriedInOrder() async throws {
        let mac = ChunkMac()
        let recording = try record(3)
        mac.failNext = 1
        _ = await queue.drain(using: mac)
        XCTAssertEqual(queue.unconfirmed(recording.id), [0, 1, 2], "nothing was confirmed")
        _ = await queue.drain(using: mac)
        XCTAssertEqual(mac.arrivals, [0, 1, 2])
        XCTAssertEqual(mac.completions.map(\.count), [3])
    }

    // S4
    func testTheMacBeingAwayForTheWholeRecordingDeletesNothingAndEverythingGoesWhenItIsBack() async throws {
        let mac = ChunkMac()
        mac.reachable = false
        let recording = try record(5, stop: false)
        let drained1 = await queue.drain(using: mac)
        XCTAssertEqual(drained1, 0, "while recording and while the Mac is away")
        queue.stop(recording.id)
        let drained2 = await queue.drain(using: mac)
        XCTAssertEqual(drained2, 0)
        XCTAssertEqual(queue.unconfirmed(recording.id), [0, 1, 2, 3, 4], "every chunk is still on the phone")
        XCTAssertEqual(queue.pending.map(\.id), [recording.id])
        mac.reachable = true
        let drained3 = await queue.drain(using: mac)
        XCTAssertEqual(drained3, 1)
        XCTAssertEqual(mac.chunks.keys.sorted(), [0, 1, 2, 3, 4])
        XCTAssertEqual(mac.completions.map(\.count), [5])
        XCTAssertEqual(queue.pending, [])
    }

    // S1, S4
    func testAChunkIsSentWhileTheRecordingRunsButTheRecordingIsCompletedOnlyAfterStop() async throws {
        let mac = ChunkMac()
        let recording = try record(2, stop: false)
        let drained4 = await queue.drain(using: mac)
        XCTAssertEqual(drained4, 0)
        XCTAssertEqual(mac.arrivals, [0, 1], "uploaded while recording")
        XCTAssertTrue(mac.completions.isEmpty)
        try queue.append(recording.id, wav: wav(2))
        queue.stop(recording.id)
        let drained5 = await queue.drain(using: mac)
        XCTAssertEqual(drained5, 1)
        XCTAssertEqual(mac.arrivals, [0, 1, 2])
        XCTAssertEqual(mac.completions.map(\.count), [3])
    }

    // S5
    func testOnlyConfirmedChunksAreDeleted() async throws {
        let mac = ChunkMac()
        let recording = try record(3, stop: false)
        // The Mac takes the first three chunks and then goes away.
        _ = await queue.drain(using: mac)
        XCTAssertEqual(mac.arrivals, [0, 1, 2])
        mac.reachable = false
        try queue.append(recording.id, wav: wav(3))
        _ = await queue.drain(using: mac)
        XCTAssertEqual(queue.unconfirmed(recording.id), [3], "confirmed chunks are gone, the new one waits")
        for index in 0..<3 { XCTAssertFalse(FileManager.default.fileExists(atPath: queue.chunkURL(recording: recording.id, index: index).path)) }
        XCTAssertEqual(try Data(contentsOf: queue.chunkURL(recording: recording.id, index: 3)), wav(3))
    }

    func testARefusedRecordingKeepsTheReasonAndDeletesItsChunks() async throws {
        let mac = ChunkMac()
        mac.refuseWith = "The recording is longer than the 4 hour limit."
        let recording = try record(2)
        let drained6 = await queue.drain(using: mac)
        XCTAssertEqual(drained6, 0)
        XCTAssertEqual(queue.pending.first?.failure, "The recording is longer than the 4 hour limit.")
        XCTAssertEqual(queue.unconfirmed(recording.id), [])
        mac.refuseWith = nil
        let drained7 = await queue.drain(using: mac)
        XCTAssertEqual(drained7, 0, "a refused recording is not sent again")
        queue.discard(recording.id)
        XCTAssertEqual(queue.pending, [])
    }

    func testARecordingTheAppDiedInIsClosedAndSentOnTheNextLaunch() async throws {
        let mac = ChunkMac()
        _ = try record(2, stop: false)
        let relaunched = MeetingRecordingQueue(folder: dir)
        relaunched.closeInterrupted()
        let drained8 = await relaunched.drain(using: mac)
        XCTAssertEqual(drained8, 1)
        XCTAssertEqual(mac.completions.map(\.count), [2])
    }

    func testARecordingWithNoAudioIsDroppedWithoutBotheringTheMac() async throws {
        let mac = ChunkMac()
        _ = try record(0)
        let drained9 = await queue.drain(using: mac)
        XCTAssertEqual(drained9, 0)
        XCTAssertTrue(mac.completions.isEmpty)
        XCTAssertEqual(queue.pending, [])
    }

    func testTheWAVHeaderCarries16kHzMono16BitAudio() {
        let data = MeetingRecordingFormat.wav(pcm: Data(count: MeetingRecordingFormat.chunkBytes))
        XCTAssertEqual(data.count, 44 + 30 * 16_000 * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(data.subdata(in: 24..<28), Data([0x80, 0x3E, 0, 0]), "16000 Hz")
        XCTAssertEqual(data[22], 1)
        XCTAssertEqual(data[34], 16)
    }
}
