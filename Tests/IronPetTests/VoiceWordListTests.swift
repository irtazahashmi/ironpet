import XCTest
@testable import IronPet
@testable import IronPetCore

/// The word list reaches the transcription request and the text that `VoiceController` delivers.
@MainActor
final class VoiceWordListTests: XCTestCase {
    private var clip: URL!
    private var dir: URL!
    private var saved: VoiceVocabulary!

    override func setUp() async throws {
        saved = VoiceVocabulary.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-vw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clip = dir.appendingPathComponent("clip.wav")
        let samples = (0..<(WAV.sampleRate * 3)).map { Int16(sin(Double($0) * 2 * .pi * 440 / Double(WAV.sampleRate)) * 3000) }
        try WAV.encode(samples).write(to: clip)
        VoiceVocabulary.shared = VoiceVocabulary(wordList: WordListStore(url: dir.appendingPathComponent("words.json")), entityNames: { [] })
        StubProtocol.requests = []
        StubProtocol.bodies = []
        StubProtocol.respond = { _ in (200, Data(#"{"text":"check the prompts in length fuse"}"#.utf8), nil) }
    }

    override func tearDown() async throws {
        VoiceVocabulary.shared = saved
        try? FileManager.default.removeItem(at: dir)
    }

    private func dictate(_ voice: VoiceController) async throws -> String? {
        voice.isEnabled = { true }
        voice.makeTranscriber = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return Transcriber(baseURL: "http://stub.test/v1", model: "m", session: URLSession(configuration: configuration),
                               prompt: VoiceVocabulary.shared.prompt())
        }
        var delivered: String?
        voice.onTranscript = { delivered = $0 }
        voice.start(.file(clip))
        for _ in 0..<100 where voice.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        voice.stop()
        for _ in 0..<200 where delivered == nil { try await Task.sleep(for: .milliseconds(20)) }
        return delivered
    }

    // S1 through VoiceController
    func testControllerDeliversTheCorrectedTranscriptAndSendsThePrompt() async throws {
        VoiceVocabulary.shared.wordList.add("Langfuse", misheard: ["length fuse"])
        let delivered = try await dictate(VoiceController())
        XCTAssertEqual(delivered, "check the prompts in Langfuse")
        let body = String(decoding: try XCTUnwrap(StubProtocol.bodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nLangfuse"))
    }

    func testControllerWithAnEmptyListDeliversRawTextAndSendsNoPrompt() async throws {
        let delivered = try await dictate(VoiceController())
        XCTAssertEqual(delivered, "check the prompts in length fuse")
        let body = String(decoding: try XCTUnwrap(StubProtocol.bodies.first), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"prompt\""))
    }

    func testMultipartHasNoPromptFieldByDefault() {
        let body = String(decoding: Transcriber.multipartBody(boundary: "b", wav: Data([1]), model: "m"), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"prompt\""))
    }
}

/// S5: correcting a word in the chat draft and adding it to the word list.
@MainActor
final class WordCorrectionTests: XCTestCase {
    private var dir: URL!
    private var saved: VoiceVocabulary!

    override func setUp() async throws {
        TestMemory.isolate()
        saved = VoiceVocabulary.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-wc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        VoiceVocabulary.shared = VoiceVocabulary(wordList: WordListStore(url: dir.appendingPathComponent("words.json")), entityNames: { [] })
    }

    override func tearDown() async throws {
        VoiceVocabulary.shared = saved
        try? FileManager.default.removeItem(at: dir)
    }

    func testCorrectingTheDraftCanAddTheWordToTheList() async {
        let h = ChatHarness()
        h.model.input = "check the prompts in length fuse"
        h.model.correctWord(heard: "length fuse", spelled: "Langfuse", addToWordList: true)
        XCTAssertEqual(h.model.input, "check the prompts in Langfuse")
        XCTAssertEqual(VoiceVocabulary.shared.wordList.terms, [WordTerm(term: "Langfuse", misheard: ["length fuse"])])
        let again = await VoiceVocabulary.shared.correct("check the prompts in length fuse")
        XCTAssertEqual(again, "check the prompts in Langfuse")
    }

    func testCorrectingWithoutAddingLeavesTheListAlone() {
        let h = ChatHarness()
        h.model.input = "say length fuse"
        h.model.correctWord(heard: "length fuse", spelled: "Langfuse", addToWordList: false)
        XCTAssertEqual(h.model.input, "say Langfuse")
        XCTAssertTrue(VoiceVocabulary.shared.wordList.terms.isEmpty)
    }
}
