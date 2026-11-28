import XCTest
@testable import IronPet
@testable import IronPetCore

private final class RoomStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"text":"hello there general kenobi","segments":[{"start":0,"end":2,"text":"hello there"},{"start":2,"end":4,"text":"general kenobi"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Two people in every chunk: one in the first two seconds, the other in the next two.
private final class TwoVoices: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    private static func unit(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[axis] = 1
        return v
    }

    func diarize(wav: URL) async throws -> ChunkDiarization {
        lock.lock(); _calls += 1; lock.unlock()
        return ChunkDiarization(speakers: [
            ChunkSpeaker(localId: "a", embedding: Self.unit(0), turns: [0...1.9]),
            ChunkSpeaker(localId: "b", embedding: Self.unit(1), turns: [2.1...3.9]),
        ])
    }
}

@MainActor
final class RoomMeetingTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-room-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func tone() throws -> URL {
        let samples = (0..<(4 * WAV.sampleRate)).map { Int16($0 / 20 % 2 == 0 ? 8000 : -8000) }
        let url = dir.appendingPathComponent("room.wav")
        try WAV.encode(samples).write(to: url)
        return url
    }

    private func roomMeeting(recognise: Bool, ready: Bool, diarizer: TwoVoices, title: String? = nil) async throws -> MeetingController {
        let controller = MeetingController()
        controller.isEnabled = { true }
        controller.meetingConfig = { var m = Config.Meetings(); m.autoSummary = false; return m }
        controller.meetingsRoot = dir.appendingPathComponent("meetings")
        controller.recogniseSpeakers = { recognise }
        controller.speakerModelsReady = { ready }
        controller.diarizer = diarizer
        controller.makeTranscriber = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RoomStub.self]
            return Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration))
        }
        try controller.startTest(mic: try tone(), them: nil, room: true, appName: "ignored", lengths: .test(2), title: title)
        try await waitFor { controller.phase == .recording }
        try await Task.sleep(for: .seconds(4.5))
        controller.stop()
        try await waitFor(seconds: 30) { controller.phase == .done }
        return controller
    }

    private func waitFor(seconds: Double = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A meeting started from a room suggestion carries the event's title from the first second.
    func testARoomMeetingStartedWithATitleIsNamedAfterIt() async throws {
        let controller = try await roomMeeting(recognise: false, ready: false, diarizer: TwoVoices(), title: "Design review")
        XCTAssertTrue(controller.isRoom)
        XCTAssertEqual(MeetingSuggestions.title(in: controller.folder!), "Design review")
    }

    func testARoomMeetingWithoutATitleHasNone() async throws {
        let controller = try await roomMeeting(recognise: false, ready: false, diarizer: TwoVoices())
        XCTAssertNil(MeetingSuggestions.title(in: controller.folder!))
    }

    /// A suggestion is only a bubble: polling the calendar leaves the recorder idle until the user presses the action.
    func testASuggestionDoesNotStartARecording() {
        let controller = MeetingController()
        controller.isEnabled = { true }
        let now = Date()
        struct One: CalendarEventSource {
            var event: CalendarEvent
            func events(from: Date, to: Date) -> [CalendarEvent] { [event] }
        }
        let suggester = RoomSuggester(
            source: One(event: CalendarEvent(id: "e", title: "Sync", location: "Room 2", start: now.addingTimeInterval(60))),
            isEnabled: { true }, isBusy: { controller.isBusy }, now: { now })
        var shown: [String] = []
        suggester.show = { shown.append($0.title) }
        suggester.poll()
        suggester.poll()
        XCTAssertEqual(shown, ["Sync"])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(controller.folder)
    }

    // S3
    func testARoomMeetingWritesOnlyRoomChunksAndOneTrack() async throws {
        let controller = try await roomMeeting(recognise: false, ready: false, diarizer: TwoVoices())
        XCTAssertTrue(controller.isRoom)
        XCTAssertEqual(controller.appName, "Room")
        let names = try FileManager.default.contentsOfDirectory(atPath: controller.folder!.path)
        let chunks = names.filter { $0.hasSuffix(".wav") }
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.hasPrefix("room-") }, "\(chunks)")
        XCTAssertTrue(controller.lines.allSatisfy { $0.track == .room })
    }

    // S4
    func testRoomChunksAreDiarizedAndNeverLabelledMe() async throws {
        let diarizer = TwoVoices()
        let controller = try await roomMeeting(recognise: true, ready: true, diarizer: diarizer)
        XCTAssertGreaterThan(diarizer.calls, 0)
        XCTAssertFalse(controller.lines.isEmpty)
        let text = try String(contentsOf: controller.transcriptURL!, encoding: .utf8)
        XCTAssertTrue(text.contains("Speaker 1: ") || text.contains("Speaker 2: "), text)
        XCTAssertTrue(controller.lines.contains { $0.speaker == "Speaker 1" })
        XCTAssertTrue(controller.lines.contains { $0.speaker == "Speaker 2" })
        XCTAssertFalse(text.contains("Me: "))
    }

    // S5
    func testRoomWithoutDiarizationUsesOneNeutralLabel() async throws {
        let diarizer = TwoVoices()
        let controller = try await roomMeeting(recognise: false, ready: true, diarizer: diarizer)
        XCTAssertEqual(diarizer.calls, 0)
        XCTAssertEqual(controller.counts.failed, 0)
        let text = try String(contentsOf: controller.transcriptURL!, encoding: .utf8)
        XCTAssertTrue(text.contains("Room: hello there"), text)
        XCTAssertFalse(text.contains("Me: "))
        XCTAssertFalse(text.contains("Speaker"))
    }

    func testRoomWithMissingModelsStillCompletes() async throws {
        let diarizer = TwoVoices()
        let controller = try await roomMeeting(recognise: true, ready: false, diarizer: diarizer)
        XCTAssertEqual(diarizer.calls, 0)
        XCTAssertTrue(try String(contentsOf: controller.transcriptURL!, encoding: .utf8).contains("Room: general kenobi"))
    }

    // S6
    func testTheLibraryMarksARoomMeetingFromItsChunksOrItsHeader() throws {
        let withChunk = dir.appendingPathComponent("2026-11-28-1000")
        try FileManager.default.createDirectory(at: withChunk, withIntermediateDirectories: true)
        try WAV.encode([0, 0]).write(to: withChunk.appendingPathComponent("room-001.wav"))
        XCTAssertEqual(MeetingLibrary.record(withChunk)?.isRoom, true)

        let withHeader = dir.appendingPathComponent("2026-11-28-1100")
        try FileManager.default.createDirectory(at: withHeader, withIntermediateDirectories: true)
        try "# Meeting 2026-11-28 11:00 (Room)\n[11:00:01] Speaker 1: hi\n".write(
            to: withHeader.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MeetingLibrary.record(withHeader)?.isRoom, true)

        let call = dir.appendingPathComponent("2026-11-28-1200")
        try FileManager.default.createDirectory(at: call, withIntermediateDirectories: true)
        try "# Meeting 2026-11-28 12:00 (Zoom)\n[12:00:01] Them: hi\n".write(
            to: call.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try WAV.encode([0, 0]).write(to: call.appendingPathComponent("mic-001.wav"))
        XCTAssertEqual(MeetingLibrary.record(call)?.isRoom, false)
    }

    func testRoomChunksAreScannedForARebuild() throws {
        XCTAssertEqual(MeetingFolderScan.chunkName("room-003.wav")?.track, .room)
        XCTAssertEqual(MeetingFolderScan.chunkName("room-003.wav")?.index, 3)
        XCTAssertTrue(MeetingTrack.me < .them && MeetingTrack.them < .room)
        XCTAssertTrue(MeetingTrack.room.hasSeveralVoices)
        XCTAssertFalse(MeetingTrack.me.hasSeveralVoices)
    }

    // S7
    func testRoomIsPreselectedWhenItWasChosenLastTime() {
        let zoom = AudioApp(bundleID: "us.zoom.xos", name: "Zoom")
        let music = AudioApp(bundleID: "com.apple.Music", name: "Music")
        XCTAssertEqual(AudioChoice.room.key, AudioApps.roomKey)
        XCTAssertEqual(AudioApps.preselect(from: [music], remembered: AudioApps.roomKey), .room)
        XCTAssertEqual(AudioApps.preselect(from: [], remembered: AudioApps.roomKey), .room)
        // A call meeting chosen last time still preselects that app.
        XCTAssertEqual(AudioApps.preselect(from: [music], remembered: "com.apple.Music"), .app(music))
        XCTAssertEqual(AudioApps.preselect(from: [zoom, music], remembered: "com.apple.Music"), .app(zoom))
    }
}
