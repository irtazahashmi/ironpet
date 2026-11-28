import IronPetKit
import XCTest
@testable import IronPetRemote

/// A microphone the test feeds by hand.
private final class ScriptedMic: MicSource {
    var onFailure: (@Sendable (String) -> Void)?
    var onInterrupted: (@Sendable (String) -> Void)?
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var stopped = false

    func start() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        return stream
    }
    func feed(seconds: Double) { continuation?.yield(Data(repeating: 3, count: Int(seconds * 32_000))) }
    func stop() { stopped = true; continuation?.finish() }
}

private final class DeniedMic: MicSource {
    var onFailure: (@Sendable (String) -> Void)?
    var onInterrupted: (@Sendable (String) -> Void)?
    func start() async throws -> AsyncStream<Data> { throw MicError.denied }
    func stop() {}
}

@MainActor
private final class FakeActivity: RecordingActivityControlling {
    private(set) var started: [Date] = []
    private(set) var ended = 0
    func start(startedAt: Date) { started.append(startedAt) }
    func end() { ended += 1 }
}

/// A Mac that keeps chunks by index, and is away until told otherwise.
private final class RecordingMac: MeetingRecordingTransport, MeetingUploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var reachable = false
    private(set) var chunks: [Int: Data] = [:]
    private(set) var completions: [Int] = []

    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }
    private func check() throws { if !reachable { throw ClientError.transport("offline") } }

    func sendRecordingChunk(id: String, index: Int, data: Data) async throws { try lock.withLock { try check(); chunks[index] = chunks[index] ?? data } }
    func completeRecording(id: String, count: Int, startedAt: Date) async throws {
        try lock.withLock {
            try check()
            guard (0..<count).allSatisfy({ chunks[$0] != nil }) else { throw ClientError.api(status: 409, code: "conflict", message: "missing") }
            completions.append(count)
        }
    }
    func beginUpload(_ start: RemoteUploadStart) async throws -> RemoteUploadStatus { throw ClientError.transport("unused") }
    func uploadStatus(id: String) async throws -> RemoteUploadStatus { throw ClientError.transport("unused") }
    func sendUploadPart(id: String, offset: Int64, data: Data) async throws -> RemoteUploadStatus { throw ClientError.transport("unused") }
    func completeUpload(id: String) async throws {}
}

@MainActor
final class MeetingRecorderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    // S1
    func testRecordAndStopSendsEveryChunkToTheMacAndCompletesTheRecording() async throws {
        let mac = RecordingMac()
        mac.setReachable(true)
        let queue = MeetingRecordingQueue(folder: dir.appendingPathComponent("recordings"))
        let mic = ScriptedMic()
        let activity = FakeActivity()
        let recorder = MeetingRecorder(queue: queue, makeSource: { mic }, activity: activity)
        let uploads = MeetingUploadsModel(queue: MeetingUploadQueue(folder: dir.appendingPathComponent("uploads")), transport: mac,
                                          recordings: queue, recordingTransport: mac, retryDelay: .milliseconds(20))
        recorder.onChunk = { uploads.kick() }
        var confirmed = 0
        uploads.onConfirmed = { confirmed += 1 }

        recorder.start()
        try await wait { recorder.state == .recording }
        XCTAssertEqual(activity.started.count, 1, "the Live Activity starts with the recording")
        mic.feed(seconds: 70)
        try await wait { mac.chunks.count == 2 }
        XCTAssertEqual(mac.chunks.count, 2, "two full 30 s chunks go out while the recording runs")
        XCTAssertTrue(mac.completions.isEmpty)
        recorder.stop()
        try await wait { !mac.completions.isEmpty }
        XCTAssertEqual(mac.completions, [3], "the last 10 s is the third chunk")
        XCTAssertEqual(mac.chunks.mapValues { MeetingRecordingFormat.wav(pcm: Data(repeating: 3, count: $0.count - 44)) == $0 }.values.filter { !$0 }.count, 0)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(activity.ended, 1, "the Live Activity ends with the recording")
        try await wait { queue.pending.isEmpty }
        XCTAssertEqual(queue.pending, [])
        XCTAssertGreaterThan(confirmed, 0, "the list of meetings reads again")
    }

    // S4
    func testTheMacBeingAwayForTheWholeRecordingKeepsEveryChunkUntilItIsBack() async throws {
        let mac = RecordingMac()
        let queue = MeetingRecordingQueue(folder: dir.appendingPathComponent("recordings"))
        let mic = ScriptedMic()
        let recorder = MeetingRecorder(queue: queue, makeSource: { mic }, activity: FakeActivity())
        let uploads = MeetingUploadsModel(queue: MeetingUploadQueue(folder: dir.appendingPathComponent("uploads")), transport: mac,
                                          recordings: queue, recordingTransport: mac, retryDelay: .milliseconds(20))
        recorder.onChunk = { uploads.kick() }
        recorder.start()
        try await wait { recorder.state == .recording }
        mic.feed(seconds: 65)
        try await wait { queue.pending.first?.chunkCount == 2 }
        recorder.stop()
        try await wait { recorder.state == .idle }
        let id = try XCTUnwrap(queue.pending.first?.id)
        XCTAssertEqual(queue.unconfirmed(id), [0, 1, 2], "nothing was deleted while the Mac was away")
        XCTAssertTrue(mac.chunks.isEmpty)
        mac.setReachable(true)
        try await wait { queue.pending.isEmpty }
        XCTAssertEqual(mac.chunks.keys.sorted(), [0, 1, 2])
        XCTAssertEqual(mac.completions, [3])
    }

    func testARecordingTheAppWasKilledInIsSentAsAMeetingOnTheNextLaunch() throws {
        let queue = MeetingRecordingQueue(folder: dir.appendingPathComponent("recordings"))
        let recording = try queue.begin()
        try queue.append(recording.id, wav: MeetingRecordingFormat.wav(pcm: Data(count: 640)))
        _ = MeetingRecorder(queue: queue, makeSource: { ScriptedMic() }, activity: FakeActivity())
        XCTAssertEqual(queue.pending.first?.stopped, true)
    }

    func testADeniedMicrophoneShowsItsReasonAndLeavesNothingBehind() async throws {
        let queue = MeetingRecordingQueue(folder: dir.appendingPathComponent("recordings"))
        let activity = FakeActivity()
        let recorder = MeetingRecorder(queue: queue, makeSource: { DeniedMic() }, activity: activity)
        recorder.start()
        try await wait { recorder.message != nil }
        XCTAssertEqual(recorder.message, MicError.denied.errorDescription)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(activity.started.isEmpty)
        XCTAssertEqual(queue.pending, [])
    }

    // S2: the parts a simulator test can reach. Background audio and the Live Activity itself need a device.
    func testTheAppDeclaresBackgroundAudioAndLiveActivities() throws {
        let info = Bundle(for: MeetingRecorder.self).infoDictionary ?? [:]
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["audio"])
        XCTAssertEqual(info["NSSupportsLiveActivities"] as? Bool, true)
        let attributes = MeetingRecordingAttributes(startedAt: Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(attributes.startedAt.timeIntervalSince1970, 1_795_000_000)
    }

    func testTheStopIntentReachesTheRecorder() async throws {
        let queue = MeetingRecordingQueue(folder: dir.appendingPathComponent("recordings"))
        let mic = ScriptedMic()
        let recorder = MeetingRecorder(queue: queue, makeSource: { mic }, activity: FakeActivity())
        recorder.start()
        try await wait { recorder.state == .recording }
        _ = try await StopMeetingRecordingIntent().perform()
        try await wait { recorder.state == .idle }
        XCTAssertTrue(mic.stopped)
        XCTAssertEqual(recorder.state, .idle)
    }
}
