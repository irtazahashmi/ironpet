#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import IronPetCore

private final class ChunkStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"text":"hello there","segments":[{"start":0,"end":2,"text":"hello there"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct OneSpeaker: SpeakerDiarizing {
    func diarize(wav: URL) async throws -> ChunkDiarization {
        var embedding = [Float](repeating: 0, count: 256)
        embedding[1] = 1
        return ChunkDiarization(speakers: [ChunkSpeaker(localId: "a", embedding: embedding, turns: [0...2])])
    }
}

@MainActor
final class MeetingRecordingChunksTests: XCTestCase {
    private var dir: URL!
    private var root: URL!
    private var library: MeetingLibrary!
    private var api: MeetingsAPI!
    private let id = UUID().uuidString

    /// A one second tone as the phone's recorder writes it.
    private func chunk(_ seed: Int16 = 8000) -> Data { WAV.encode((0..<WAV.sampleRate).map { $0 / 20 % 2 == 0 ? seed : -seed }) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-chunks-\(UUID().uuidString)")
        root = dir.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = MeetingLibrary(root: root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkStub.self]
        library.regenerator.makeTranscriber = { Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration)) }
        library.regenerator.recogniseSpeakers = { true }
        library.regenerator.speakerModelsReady = { true }
        library.regenerator.diarizer = OneSpeaker()
        library.regenerator.meetingConfig = { Config.Meetings() }
        library.regenerator.summarize = { _, _, _, _ in "## Summary\nThey said hello.\n" }
        library.importer.makeChunker = { Chunker(minSamples: WAV.sampleRate, maxSamples: 2 * WAV.sampleRate) }
        api = MeetingsAPI(recorder: UnsupportedMeetingRecorder(), library: library)
        api.recordings = MeetingRecordingChunks(folder: dir.appendingPathComponent("recordings"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    // S3
    func testAChunkSentTwiceIsKeptOnceAndTheRecordingNeedsEveryIndex() throws {
        let store = api.recordings
        XCTAssertTrue(try store.store(id: id, index: 0, wav: chunk(8000)))
        XCTAssertFalse(try store.store(id: id, index: 0, wav: chunk(1000)), "a retry changes nothing")
        XCTAssertEqual(try Data(contentsOf: store.files(id: id, count: 1)[0]), chunk(8000), "the first copy stays")
        XCTAssertThrowsError(try store.files(id: id, count: 3)) { XCTAssertEqual($0 as? MeetingRecordingChunks.Failure, .missing([1, 2])) }
        try store.store(id: id, index: 2, wav: chunk())
        try store.store(id: id, index: 1, wav: chunk())
        XCTAssertEqual(try store.files(id: id, count: 3).map(\.lastPathComponent), ["000000.wav", "000001.wav", "000002.wav"], "in index order")
    }

    func testAChunkThatIsNotOurWAVIsRefused() {
        XCTAssertThrowsError(try api.recordings.store(id: id, index: 0, wav: Data(repeating: 1, count: 100)))
        XCTAssertThrowsError(try api.recordings.store(id: "../x", index: 0, wav: chunk()))
        XCTAssertThrowsError(try api.recordings.store(id: id, index: MeetingRecordingChunks.maxChunks, wav: chunk()))
    }

    // S1, S5
    func testACompletedRecordingBecomesARoomMeetingAndTheMacKeepsTheAudio() async throws {
        for index in [1, 0, 2] { try api.storeChunk(id: id, index: index, data: chunk()) }
        do {
            try api.completeRecording(id: id, count: 4, startedAt: Date())
            XCTFail("chunk 3 is missing")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .conflict)
            XCTAssertTrue(error.message.contains("3"), error.message)
        }
        XCTAssertEqual(library.meetings.count, 0, "an incomplete recording makes no meeting")
        let started = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9, minute: 30))!
        let task = try api.completeRecording(id: id, count: 3, startedAt: started)
        let again = try api.completeRecording(id: id, count: 3, startedAt: started)
        await task.value
        await again.value
        library.reload()
        XCTAssertEqual(library.meetings.map(\.id), ["2026-11-28-0930"], "asking again after a lost answer makes no second meeting")
        let record = try XCTUnwrap(library.meetings.first)
        let audio = try FileManager.default.contentsOfDirectory(atPath: record.folder.path).filter { $0.hasPrefix("room-") && $0.hasSuffix(".wav") }.sorted()
        XCTAssertEqual(audio, ["room-001.wav", "room-002.wav"], "3 s of audio in chunks of 1 to 2 s, kept in the meeting")
        XCTAssertTrue(try String(contentsOf: record.transcriptURL, encoding: .utf8).contains("hello there"))
        XCTAssertEqual(try String(contentsOf: record.summaryURL, encoding: .utf8), "## Summary\nThey said hello.\n")
        XCTAssertThrowsError(try api.recordings.files(id: id, count: 1), "the upload chunks are cleaned up")
    }

    // S5
    func testAChunkSentAfterTheRecordingWasCompletedIsAcceptedAndIgnored() async throws {
        try api.storeChunk(id: id, index: 0, data: chunk())
        let task = try api.completeRecording(id: id, count: 1, startedAt: Date())
        await task.value
        XCTAssertNoThrow(try api.storeChunk(id: id, index: 0, data: chunk()))
        XCTAssertThrowsError(try api.recordings.files(id: id, count: 1))
    }
}
