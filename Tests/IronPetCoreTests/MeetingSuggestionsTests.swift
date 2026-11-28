#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import IronPetCore

private final class SuggestStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"text":"Thanks Jonas","segments":[{"start":0,"end":2,"text":"Thanks Jonas"}]}"#
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

final class MeetingSuggestionsParseTests: XCTestCase {
    func testTheSectionIsSplitOffAndParsed() {
        let answer = "## Summary\nThey met.\n\n## Action items\nNone.\n\n## Suggestions\nTitle: Launch planning\nSpeaker 1: Jonas\nSpeaker 2: \"Ana\"\n"
        let (summary, found) = MeetingSuggestions.parse(answer)
        XCTAssertEqual(summary, "## Summary\nThey met.\n\n## Action items\nNone.")
        XCTAssertEqual(found.title, "Launch planning")
        XCTAssertEqual(found.speakers, ["Speaker 1": "Jonas", "Speaker 2": "Ana"])
    }

    func testNoneAndUnusableNamesGiveNoSuggestion() {
        let (_, found) = MeetingSuggestions.parse("## Summary\nx\n\n## Suggestions\nSpeaker 1: Me\nSpeaker 2: Speaker 3\nSpeaker 3: unknown\nNone.\n")
        XCTAssertTrue(found.isEmpty)
    }

    func testAnAnswerWithoutTheSectionIsUnchanged() {
        let answer = "## Summary\nx\n"
        let (summary, found) = MeetingSuggestions.parse(answer)
        XCTAssertEqual(summary, answer)
        XCTAssertTrue(found.isEmpty)
    }

    func testOnlyVoicesInTheTranscriptAreKept() {
        let found = MeetingSuggestions(title: "T", speakers: ["Speaker 1": "Jonas", "Speaker 7": "Ghost"])
        let kept = found.limited(toTranscript: "# Meeting\n[14:00:00] Speaker 1: hi\n")
        XCTAssertEqual(kept.speakers, ["Speaker 1": "Jonas"])
        XCTAssertEqual(kept.title, "T")
    }

    @MainActor
    func testTheSuggestionInstructionIsOnlyInTheRoomPrompt() {
        XCTAssertFalse(MeetingSummary.prompt(transcript: "T").contains("## Suggestions"))
        XCTAssertTrue(MeetingSummary.prompt(transcript: "T", suggest: true).contains("## Suggestions"))
    }
}

@MainActor
final class MeetingSuggestionsTests: XCTestCase {
    private var dir: URL!
    private var root: URL!
    private var library: MeetingLibrary!
    private var asked: [Bool] = []
    private var answer = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-suggest-\(UUID().uuidString)")
        root = dir.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = MeetingLibrary(root: root)
        asked = []
        let regenerator = library.regenerator
        regenerator.makeTranscriber = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SuggestStub.self]
            return Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration))
        }
        regenerator.recogniseSpeakers = { true }
        regenerator.speakerModelsReady = { true }
        regenerator.diarizer = OneVoice()
        regenerator.meetingConfig = { Config.Meetings() }
        regenerator.summarize = { [unowned self] _, _, _, suggest in
            asked.append(suggest)
            return answer
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func meeting(prefixes: [String]) throws -> MeetingRecord {
        let folder = root.appendingPathComponent("2026-11-28-0930")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in prefixes {
            let samples = (0..<(3 * WAV.sampleRate)).map { Int16($0 / 20 % 2 == 0 ? 8000 : -8000) }
            try WAV.encode(samples).write(to: folder.appendingPathComponent("\(name).wav"))
        }
        library.reload()
        return try XCTUnwrap(library.meetings.first)
    }

    private func text(_ record: MeetingRecord, _ name: String) -> String? {
        try? String(contentsOf: record.folder.appendingPathComponent(name), encoding: .utf8)
    }

    // S1
    func testARoomSummaryReturnsATitleAndTheNameOfAnAddressedSpeaker() async throws {
        answer = "## Summary\nA talk.\n\n## Decisions\nNone.\n\n## Action items\nNone.\n\n## Suggestions\nTitle: Launch planning\nSpeaker 1: Jonas\n"
        let record = try meeting(prefixes: ["room-001", "room-002"])
        let ok = await library.regenerator.regenerate(record, mode: .full)
        XCTAssertTrue(ok, library.regenerator.errors.values.joined())
        XCTAssertEqual(asked, [true])
        let found = library.suggestions(for: record.id)
        XCTAssertEqual(found.title, "Launch planning")
        XCTAssertEqual(found.speakers, ["Speaker 1": "Jonas"])
        XCTAssertFalse(try XCTUnwrap(text(record, "summary.md")).contains("Suggestions"), "the section is not part of the saved summary")
    }

    // S2
    func testNoSpeakerNameIsSuggestedWhenNobodyIsNamed() async throws {
        answer = "## Summary\nA talk.\n\n## Suggestions\nTitle: Standup\nSpeaker 4: Nobody In The Transcript\n"
        let record = try meeting(prefixes: ["room-001"])
        await library.regenerator.regenerate(record, mode: .full)
        let found = library.suggestions(for: record.id)
        XCTAssertEqual(found.title, "Standup")
        XCTAssertTrue(found.speakers.isEmpty)

        answer = "## Summary\nA talk.\n\n## Suggestions\nNone.\n"
        await library.regenerator.regenerate(try XCTUnwrap(library.meetings.first), mode: .full)
        XCTAssertTrue(library.suggestions(for: record.id).isEmpty)
        XCTAssertNil(text(record, MeetingSuggestions.fileName), "nothing left to suggest means no file")
    }

    // S3
    func testAcceptingASpeakerNamesTheLinesAndStoresTheVoice() async throws {
        answer = "## Summary\nSpeaker 1 thanked the team.\n\n## Suggestions\nSpeaker 1: Jonas\n"
        let key = SymmetricKey(size: .bits256)
        let store = VoiceStore(url: dir.appendingPathComponent("voices.enc"), key: { key }, modelId: "test")
        library.regenerator.voiceStore = store
        let record = try meeting(prefixes: ["room-001"])
        await library.regenerator.regenerate(record, mode: .full)
        // The two seconds of a test chunk are too short to store, so give the voice a real length.
        var voice = try XCTUnwrap(library.regenerator.speakerVoices[record.id]?["Speaker 1"])
        voice.seconds = 60
        library.regenerator.speakerVoices[record.id]?["Speaker 1"] = voice

        try library.acceptSpeaker(record.id, label: "Speaker 1", name: "Jonas")

        XCTAssertTrue(try XCTUnwrap(text(record, "transcript.md")).contains("Jonas: Thanks Jonas"))
        XCTAssertTrue(try XCTUnwrap(text(record, "summary.md")).contains("Jonas thanked the team."))
        XCTAssertEqual(store.voices().map(\.name), ["Jonas"], "the voice is stored the way naming a speaker after a meeting does")
        XCTAssertTrue(library.suggestions(for: record.id).speakers.isEmpty)
    }

    func testAcceptingAnEditedNameAndRefusingBadInput() async throws {
        answer = "## Summary\nx\n\n## Suggestions\nSpeaker 1: Jon\n"
        let record = try meeting(prefixes: ["room-001"])
        await library.regenerator.regenerate(record, mode: .full)
        XCTAssertThrowsError(try library.acceptSpeaker(record.id, label: "Speaker 1", name: "  ")) { XCTAssertEqual($0 as? MeetingLibrary.SuggestionError, .emptyName) }
        XCTAssertThrowsError(try library.acceptSpeaker(record.id, label: "Speaker 9", name: "Ana")) { XCTAssertEqual($0 as? MeetingLibrary.SuggestionError, .notSuggested) }
        try library.acceptSpeaker(record.id, label: "Speaker 1", name: "Jonas")
        XCTAssertTrue(try XCTUnwrap(text(record, "transcript.md")).contains("Jonas:"))
    }

    // S4
    func testAcceptingATitleStoresItAndShowsItInTheListsForMacAndPhone() async throws {
        answer = "## Summary\nx\n\n## Suggestions\nTitle: Launch planning\n"
        let record = try meeting(prefixes: ["room-001"])
        await library.regenerator.regenerate(record, mode: .full)
        XCTAssertNil(try XCTUnwrap(library.meetings.first).title, "a suggestion is not a title yet")

        try library.acceptTitle(record.id, title: "  Launch planning, week 3 ")

        XCTAssertEqual(text(record, MeetingSuggestions.titleFileName), "Launch planning, week 3\n")
        XCTAssertEqual(library.meetings.first?.title, "Launch planning, week 3")
        XCTAssertNil(library.suggestions(for: record.id).title)

        let api = MeetingsAPI(recorder: UnsupportedMeetingRecorder(), library: library)
        let info = try XCTUnwrap(api.list().first)
        XCTAssertEqual(info.title, "Launch planning, week 3")

        try library.acceptTitle(record.id, title: "")
        XCTAssertNil(library.meetings.first?.title, "an empty title clears it")
    }

    func testARegenerationKeepsTheTitleTheUserChose() async throws {
        answer = "## Summary\nx\n\n## Suggestions\nTitle: Other\n"
        let record = try meeting(prefixes: ["room-001"])
        try library.acceptTitle(record.id, title: "Mine")
        await library.regenerator.regenerate(record, mode: .full)
        XCTAssertEqual(library.meetings.first?.title, "Mine")
    }

    // S5
    func testACallMeetingIsNotAskedForSuggestionsAndKeepsItsSummary() async throws {
        answer = "## Summary\nx\n\n## Suggestions\nTitle: Should be ignored\nSpeaker 1: Jonas\n"
        let record = try meeting(prefixes: ["mic-001", "them-001"])
        XCTAssertFalse(record.isRoom)
        await library.regenerator.regenerate(record, mode: .full)
        XCTAssertEqual(asked, [false])
        XCTAssertTrue(library.suggestions(for: record.id).isEmpty)
        XCTAssertEqual(text(record, "summary.md"), answer + "", "a call's answer is saved as the agent wrote it")
    }
}
