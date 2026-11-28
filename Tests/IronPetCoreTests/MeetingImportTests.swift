#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import IronPetCore

/// A transcription server that answers every request with the same two-second segment.
private final class ImportStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"text":"hello there","segments":[{"start":0,"end":2,"text":"hello there"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct OneVoice: SpeakerDiarizing {
    func diarize(wav: URL) async throws -> ChunkDiarization {
        var embedding = [Float](repeating: 0, count: 256)
        embedding[1] = 1
        return ChunkDiarization(speakers: [ChunkSpeaker(localId: "a", embedding: embedding, turns: [0...2])])
    }
}

/// Reports a length without reading the file, and plays `seconds` of a tone.
private struct StubTranscoder: AudioTranscoder {
    var reportedSeconds: Double? = 3
    var playSeconds = 3
    var decodes = true

    func wav(from file: URL, maxSeconds: Double) throws -> Data? { nil }
    func duration(of file: URL) -> Double? { reportedSeconds }
    func stream(from file: URL, body: ([Int16]) throws -> Void) throws -> Bool {
        guard decodes else { return false }
        let tone = (0..<(playSeconds * WAV.sampleRate)).map { Int16($0 / 20 % 2 == 0 ? 8000 : -8000) }
        var start = 0
        while start < tone.count {
            try body(Array(tone[start..<min(start + WAV.sampleRate, tone.count)]))
            start += WAV.sampleRate
        }
        return true
    }
}

@MainActor
final class MeetingImportTests: XCTestCase {
    private var dir: URL!
    private var root: URL!
    private var library: MeetingLibrary!
    private let summary = "## Summary\nThey said hello.\n\n## Action items\n- [ ] Reply (owner: Me)\n"

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-import-\(UUID().uuidString)")
        root = dir.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = MeetingLibrary(root: root)
        let regenerator = library.regenerator
        regenerator.makeTranscriber = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImportStub.self]
            return Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration))
        }
        regenerator.recogniseSpeakers = { true }
        regenerator.speakerModelsReady = { true }
        regenerator.diarizer = OneVoice()
        regenerator.meetingConfig = { Config.Meetings() }
        regenerator.summarize = { [summary] _, _, _, _ in summary }
        library.importer.transcoder = StubTranscoder()
        library.importer.fileSize = { _ in 1000 }
        library.importer.creationDate = { _ in nil }
        library.importer.makeChunker = { Chunker(minSamples: WAV.sampleRate, maxSamples: 2 * WAV.sampleRate) }
        library.importer.now = { Self.date(2026, 11, 28, 9, 30) }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private nonisolated static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func folders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    // S1
    func testImportBuildsTranscriptSpeakersAndSummaryWithTheRoomPipeline() async throws {
        let record = try await library.importer.importAudio(file: file("standup.m4a"))
        XCTAssertEqual(folders(), ["2026-11-28-0930"])
        let chunks = try FileManager.default.contentsOfDirectory(atPath: record.folder.path).filter { $0.hasSuffix(".wav") }.sorted()
        XCTAssertEqual(chunks, ["room-001.wav", "room-002.wav"], "a 3 s file with 1 to 2 s chunks")
        let transcript = try String(contentsOf: record.transcriptURL, encoding: .utf8)
        XCTAssertTrue(transcript.hasPrefix("# Meeting 2026-11-28 09:30 (Imported audio)"), transcript)
        XCTAssertTrue(transcript.contains("Speaker 1: hello there"), "speakers are told apart as in a room recording: \(transcript)")
        XCTAssertEqual(try String(contentsOf: record.summaryURL, encoding: .utf8), summary)
        XCTAssertTrue(record.hasAudio)
        XCTAssertTrue(library.meetings.contains { $0.id == record.id })
    }

    // S1
    func testAFailedTranscriptionKeepsTheMeetingForRegenerate() async throws {
        library.regenerator.summarize = { _, _, _, _ in throw RegenerationError(message: "The agent is not signed in.") }
        do {
            _ = try await library.importer.importAudio(file: file("standup.wav"))
            XCTFail("expected an error")
        } catch let error as MeetingImportError {
            XCTAssertTrue(error.message.contains("The agent is not signed in."), error.message)
            XCTAssertTrue(error.message.contains("Regenerate"), error.message)
        }
        XCTAssertEqual(folders(), ["2026-11-28-0930"])
        XCTAssertTrue(library.meetings.first?.hasAudio == true)
    }

    // S4
    func testAnotherFormatIsRefusedAndCreatesNoMeeting() async {
        for name in ["talk.ogg", "clip.mp4", "notes"] {
            do {
                _ = try await library.importer.importAudio(file: file(name))
                XCTFail("\(name) should be refused")
            } catch let error as MeetingImportError {
                XCTAssertTrue(error.message.contains("m4a, mp3 and wav"), error.message)
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(folders(), [])
        XCTAssertNotNil(library.importer.lastError)
    }

    // S4
    func testAFileOverOneGigabyteIsRefusedWithTheLimit() async {
        library.importer.fileSize = { _ in MeetingImporter.maxBytes + 1 }
        await assertRefused(file("big.wav"), contains: "1 GB")
        library.importer.fileSize = { _ in MeetingImporter.maxBytes }
        XCTAssertNoThrow(try library.importer.validate(file("exact.wav")))
    }

    // S4
    func testAFileOverFourHoursIsRefusedWithTheLimit() async {
        library.importer.transcoder = StubTranscoder(reportedSeconds: 4 * 3600 + 1)
        await assertRefused(file("long.mp3"), contains: "4 hour")
        library.importer.transcoder = StubTranscoder(reportedSeconds: 4 * 3600)
        XCTAssertNoThrow(try library.importer.validate(file("exact.mp3")))
    }

    // S4
    func testAFileThatCannotBeDecodedLeavesNoFolder() async {
        library.importer.transcoder = StubTranscoder(decodes: false)
        await assertRefused(file("broken.m4a"), contains: "could not be decoded")
        library.importer.transcoder = StubTranscoder(reportedSeconds: nil)
        await assertRefused(file("unreadable.m4a"), contains: "could not be read as audio")
    }

    private func assertRefused(_ url: URL, contains text: String, line: UInt = #line) async {
        do {
            _ = try await library.importer.importAudio(file: url)
            XCTFail("should be refused", line: line)
        } catch let error as MeetingImportError {
            XCTAssertTrue(error.message.contains(text), error.message, line: line)
        } catch { XCTFail("\(error)", line: line) }
        XCTAssertEqual(folders(), [], "no meeting is created", line: line)
    }

    // S5
    func testTheMeetingTakesTheFilesCreationDate() async throws {
        library.importer.creationDate = { _ in Self.date(2026, 3, 2, 14, 5) }
        let record = try await library.importer.importAudio(file: file("old.m4a"))
        XCTAssertEqual(record.id, "2026-03-02-1405")
        XCTAssertEqual(record.date, Self.date(2026, 3, 2, 14, 5))
        let transcript = try String(contentsOf: record.transcriptURL, encoding: .utf8)
        XCTAssertTrue(transcript.hasPrefix("# Meeting 2026-03-02 14:05"), transcript)
    }

    // S5
    func testWithoutACreationDateTheMeetingIsDatedAtTheImport() async throws {
        let record = try await library.importer.importAudio(file: file("new.m4a"))
        XCTAssertEqual(record.id, "2026-11-28-0930")
        let second = try await library.importer.importAudio(file: file("again.m4a"))
        XCTAssertEqual(second.id, "2026-11-28-0930-2", "a second import in the same minute gets a suffix")
    }

    // S6
    func testTheAPICallRunsTheSameImportFromAPath() async throws {
        let api = MeetingsAPI(recorder: UnsupportedMeetingRecorder(), library: library)
        let info = try await api.importAudio(ImportMeetingRequest(path: file("standup.m4a").path))
        XCTAssertEqual(info.id, "2026-11-28-0930")
        XCTAssertTrue(info.hasSummary)
        XCTAssertTrue(info.hasTranscript)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(api.meetings.map(\.id), [info.id])
    }

    // S6
    func testTheAPICallRunsTheSameImportFromTheFileBody() async throws {
        let api = MeetingsAPI(recorder: UnsupportedMeetingRecorder(), library: library)
        let info = try await api.importAudio(ImportMeetingRequest(body: Data([1, 2, 3]), fileName: "standup.mp3"))
        XCTAssertEqual(info.id, "2026-11-28-0930")
        XCTAssertTrue(info.hasSummary)
    }

    // S6
    func testTheAPICallRefusesABadRequestAndAnUnsupportedFile() async {
        let api = MeetingsAPI(recorder: UnsupportedMeetingRecorder(), library: library)
        for request in [ImportMeetingRequest(), ImportMeetingRequest(path: "/a.m4a", body: Data([1]), fileName: "a.m4a"),
                        ImportMeetingRequest(body: Data([1])), ImportMeetingRequest(path: file("a.flac").path)] {
            do {
                _ = try await api.importAudio(request)
                XCTFail("should be refused: \(request)")
            } catch let error as APIError {
                XCTAssertEqual(error.code, .invalid)
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(folders(), [])
    }

    // S2, S3
    func testDropAndOpenWithStartTheSameImport() async throws {
        let api = MeetingsAPI(recorder: UnsupportedMeetingRecorder(), library: library)
        XCTAssertNil(api.startImport(of: []))
        XCTAssertNil(api.startImport(of: [URL(string: "ironpet://meeting_abc")!]), "a link is not a file")
        let task = try XCTUnwrap(api.startImport(of: [file("one.m4a"), file("two.wav")]))
        await task.value
        XCTAssertEqual(folders(), ["2026-11-28-0930", "2026-11-28-0930-2"])
        XCTAssertNil(api.importError)
    }

    // S2, S4
    func testADroppedFileOfAnotherFormatShowsTheLimit() async throws {
        let api = MeetingsAPI(recorder: UnsupportedMeetingRecorder(), library: library)
        await api.startImport(of: [file("clip.mov")])?.value
        XCTAssertEqual(folders(), [])
        XCTAssertTrue(api.importError?.contains("m4a, mp3 and wav") == true)
    }

    // S3
    func testInfoPlistDeclaresTheThreeAudioTypes() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/bundle.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "<key>CFBundleDocumentTypes</key>"))
        let declaration = String(text[start.upperBound...].prefix { $0 != "\n" })
        for ext in ["m4a", "mp3", "wav"] { XCTAssertTrue(declaration.contains("<string>\(ext)</string>"), ext) }
        XCTAssertEqual(MeetingImporter.extensions, ["m4a", "mp3", "wav"])
    }

    // MARK: Upload from the phone

    private func uploadFolder() -> URL { dir.appendingPathComponent("uploads") }

    private func uploadAPI() -> MeetingsAPI {
        let api = MeetingsAPI(recorder: UnsupportedMeetingRecorder(), library: library)
        api.uploads = MeetingUploads(folder: uploadFolder())
        return api
    }

    // S1
    func testAnUploadInPartsBecomesAMeetingAndItsPartsAreDeleted() async throws {
        let api = uploadAPI()
        let id = UUID().uuidString
        let bytes = Data((0..<10).map { UInt8($0) })
        XCTAssertEqual(try api.beginUpload(id: id, fileName: "standup.m4a", size: 10).received, 0)
        XCTAssertEqual(try api.appendUpload(id: id, offset: 0, data: bytes.prefix(6)).received, 6)
        XCTAssertEqual(try api.appendUpload(id: id, offset: 6, data: bytes.suffix(4)).received, 10)
        let task = try api.completeUpload(id: id)
        await task.value
        XCTAssertEqual(folders(), ["2026-11-28-0930"])
        XCTAssertTrue(api.meetings.first?.hasSummary == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: uploadFolder().path), [], "nothing of the upload is left")
    }

    // S3
    func testAPartThatIsSentAgainOrOutOfOrderIsRefusedWithTheAmountHeld() throws {
        let uploads = MeetingUploads(folder: uploadFolder())
        let id = UUID().uuidString
        _ = try uploads.begin(id: id, fileName: "a.wav", size: 8)
        _ = try uploads.append(id: id, offset: 0, data: Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try uploads.append(id: id, offset: 0, data: Data([1, 2, 3, 4]))) { XCTAssertEqual($0 as? MeetingUploads.Failure, .offset(held: 4)) }
        XCTAssertThrowsError(try uploads.append(id: id, offset: 6, data: Data([5, 6]))) { XCTAssertEqual($0 as? MeetingUploads.Failure, .offset(held: 4)) }
        XCTAssertThrowsError(try uploads.completed(id: id)) { XCTAssertEqual($0 as? MeetingUploads.Failure, .offset(held: 4)) }
        XCTAssertThrowsError(try uploads.append(id: id, offset: 4, data: Data(count: 5))) { XCTAssertEqual($0 as? MeetingUploads.Failure, .invalid("the part goes past the end of the file")) }
        // A new store on the same folder, as after a restart of the app, continues where the file ends.
        let again = MeetingUploads(folder: uploadFolder())
        XCTAssertEqual(try again.begin(id: id, fileName: "a.wav", size: 8).received, 4)
        XCTAssertEqual(try again.append(id: id, offset: 4, data: Data([5, 6, 7, 8])).received, 8)
        XCTAssertEqual(try Data(contentsOf: again.completed(id: id)), Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    // S4
    func testAnUploadOfTheWrongKindOrSizeIsRefusedWithTheMacsMessages() async throws {
        let api = uploadAPI()
        for (name, size, text) in [("talk.ogg", Int64(10), "m4a, mp3 and wav"), ("big.wav", MeetingImporter.maxBytes + 1, "1 GB")] {
            XCTAssertThrowsError(try api.beginUpload(id: UUID().uuidString, fileName: name, size: size)) {
                let error = try? XCTUnwrap($0 as? APIError)
                XCTAssertEqual(error?.code, .invalid)
                XCTAssertTrue(error?.message.contains(text) == true, "\(error?.message ?? "")")
            }
        }
        XCTAssertThrowsError(try api.beginUpload(id: "../x", fileName: "a.wav", size: 5), "the id names a folder")
        // The length is known only once the file is whole, and the answer is the one the Mac's import gives.
        library.importer.transcoder = StubTranscoder(reportedSeconds: MeetingImporter.maxSeconds + 1)
        let id = UUID().uuidString
        _ = try api.beginUpload(id: id, fileName: "long.m4a", size: 3)
        _ = try api.appendUpload(id: id, offset: 0, data: Data([1, 2, 3]))
        XCTAssertThrowsError(try api.completeUpload(id: id)) { XCTAssertTrue(($0 as? APIError)?.message.contains("4 hour") == true) }
        XCTAssertEqual(folders(), [])
        XCTAssertThrowsError(try api.uploadStatus(id: id), "a refused file is deleted")
    }

    // S3
    func testAnIncompleteUploadCannotBeCompleted() throws {
        let api = uploadAPI()
        let id = UUID().uuidString
        _ = try api.beginUpload(id: id, fileName: "a.wav", size: 8)
        _ = try api.appendUpload(id: id, offset: 0, data: Data([1, 2, 3]))
        XCTAssertThrowsError(try api.completeUpload(id: id)) { XCTAssertEqual(($0 as? APIError)?.code, .conflict) }
        XCTAssertEqual(try api.uploadStatus(id: id).received, 3)
    }
}
