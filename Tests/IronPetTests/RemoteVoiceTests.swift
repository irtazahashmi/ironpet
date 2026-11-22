import IronPetKit
import XCTest
@testable import IronPet
@testable import IronPetCore

/// The phone's voice socket without the socket: frames in, messages out, the voice server stubbed.
@MainActor
final class RemoteVoiceTests: XCTestCase {
    private var session: ChatSession!
    private var api: IronPetAPI!
    private var voice: RemoteVoice!
    private var out: [RemoteVoice.Output] = []
    private var logged: [String] = []
    private let device = "phone-1"

    override func setUp() async throws {
        session = ChatSession(restore: false, speech: SpeechPlayer())
        session.workspace = FileManager.default.temporaryDirectory
        api = APITestSupport.makeAPI(chat: session)
        api.settings.update { $0.voice.enabled = true }
        out = []
        logged = []
        voice = RemoteVoice(api: api, device: device) { [unowned self] in out.append($0) }
        voice.log = { [unowned self] in logged.append($0) }
    }

    override func tearDown() async throws { voice.close() }

    // MARK: Helpers

    private func fixtureSamples() throws -> [Int16] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("IronPetCoreTests/Fixtures/thank-you.wav")
        let samples = WAV.samples(of: try Data(contentsOf: url))
        XCTAssertFalse(samples.isEmpty)
        return samples
    }

    private func pcm(_ samples: ArraySlice<Int16>) -> Data {
        var data = Data()
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func start(_ id: String = "v1", mode: VoiceMode = .draft) { voice.receive(text: VoiceClientMessage.start(id: id, mode: mode).json) }
    private func end(_ id: String = "v1") { voice.receive(text: VoiceClientMessage.end(id: id).json) }

    private var messages: [VoiceServerMessage] {
        out.compactMap { if case .text(let text) = $0 { return VoiceServerMessage.parse(text) } else { return nil } }
    }

    private func wait(_ what: String = "output", until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func transcript() -> (id: String, text: String)? {
        for case .transcript(let id, let text) in messages { return (id, text) }
        return nil
    }

    // MARK: S1

    func testFramesBecomeTheWAVTheTranscriberReceives() async throws {
        let samples = try fixtureSamples()
        var received: Data?
        api.voice.transcribeAudio = { audio, name, mime in received = audio; return "hello there" }
        start()
        var seq: UInt32 = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + VoiceWire.frameSamples, samples.count)
            voice.receive(binary: VoiceWire.audioFrame(seq: seq, pcm: pcm(samples[offset..<end])))
            seq += 1
            offset = end
        }
        end()
        await wait("the transcript") { transcript() != nil }
        XCTAssertEqual(transcript()?.id, "v1")
        XCTAssertEqual(transcript()?.text, "hello there")
        XCTAssertEqual(WAV.samples(of: try XCTUnwrap(received)), samples, "the stub receives the original samples")
        XCTAssertTrue(logged.isEmpty)
    }

    func testDuplicateAndShuffledFramesChangeNothing() async throws {
        let samples = Array(try fixtureSamples().prefix(VoiceWire.frameSamples * 4))
        var received: Data?
        api.voice.transcribeAudio = { audio, _, _ in received = audio; return "ok" }
        start()
        let frames = (0..<4).map { VoiceWire.audioFrame(seq: UInt32($0), pcm: pcm(samples[$0 * VoiceWire.frameSamples..<($0 + 1) * VoiceWire.frameSamples])) }
        for index in [2, 0, 1, 1, 3, 0] { voice.receive(binary: frames[index]) }
        end()
        await wait("the transcript") { transcript() != nil }
        XCTAssertEqual(WAV.samples(of: try XCTUnwrap(received)), samples)
    }

    func testSendModePutsTheTextInTheChatAsAMessageFromThisDevice() async throws {
        var prompts: [String] = []
        session.turnRunner = { turn, _ in prompts.append(turn.prompt) }
        api.voice.transcribeAudio = { _, _, _ in "run the tests" }
        start(mode: .send)
        voice.receive(binary: VoiceWire.audioFrame(seq: 0, pcm: Data(count: VoiceWire.frameBytes)))
        end()
        await wait("the transcript") { transcript() != nil }
        await wait("the turn") { !prompts.isEmpty }
        XCTAssertEqual(transcript()?.text, "run the tests")
        XCTAssertTrue(prompts[0].contains("run the tests"))
        XCTAssertTrue(session.items.contains { $0.origin == ChatOrigin.iosClient })
    }

    func testDraftModeSendsNothingToTheChat() async throws {
        var prompts: [String] = []
        session.turnRunner = { turn, _ in prompts.append(turn.prompt) }
        api.voice.transcribeAudio = { _, _, _ in "just a draft" }
        start(mode: .draft)
        voice.receive(binary: VoiceWire.audioFrame(seq: 0, pcm: Data(count: VoiceWire.frameBytes)))
        end()
        await wait("the transcript") { transcript() != nil }
        XCTAssertEqual(transcript()?.text, "just a draft")
        XCTAssertTrue(prompts.isEmpty)
    }

    func testAFailedTranscriptionIsAnError() async throws {
        api.voice.transcribeAudio = { _, _, _ in throw TranscriptionError.timedOut }
        start()
        voice.receive(binary: VoiceWire.audioFrame(seq: 0, pcm: Data(count: VoiceWire.frameBytes)))
        end()
        await wait("the error") { messages.contains { if case .error = $0 { return true } else { return false } } }
        XCTAssertNil(transcript())
    }

    func testAnUnsupportedFormatIsRefused() {
        voice.receive(text: #"{"type":"voice.start","id":"v9","format":"pcm_s16le","rate":44100,"channels":2,"mode":"draft"}"#)
        guard case .error(let id, _)? = messages.first else { return XCTFail("expected voice.error, got \(messages)") }
        XCTAssertEqual(id, "v9")
    }

    func testCancelDropsTheStream() async throws {
        var called = false
        api.voice.transcribeAudio = { _, _, _ in called = true; return "x" }
        start()
        voice.receive(binary: VoiceWire.audioFrame(seq: 0, pcm: Data(count: VoiceWire.frameBytes)))
        voice.receive(text: VoiceClientMessage.cancel(id: "v1").json)
        end()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(called)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: S2

    func testAMissingFrameBecomesSilenceAndIsLogged() async throws {
        var received: Data?
        api.voice.transcribeAudio = { audio, _, _ in received = audio; return "gap" }
        let loud = Int16(1000)
        start()
        for seq in [0, 1, 4, 5] as [UInt32] {
            voice.receive(binary: VoiceWire.audioFrame(seq: seq, pcm: pcm(ArraySlice(repeating: loud, count: VoiceWire.frameSamples))))
        }
        end()
        await wait("the transcript") { transcript() != nil }
        let samples = WAV.samples(of: try XCTUnwrap(received))
        XCTAssertEqual(samples.count, 6 * VoiceWire.frameSamples, "frames 2 and 3 keep their place")
        XCTAssertTrue(samples[(2 * VoiceWire.frameSamples)..<(4 * VoiceWire.frameSamples)].allSatisfy { $0 == 0 })
        XCTAssertTrue(samples[0..<(2 * VoiceWire.frameSamples)].allSatisfy { $0 == loud })
        XCTAssertTrue(samples[(4 * VoiceWire.frameSamples)...].allSatisfy { $0 == loud })
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("2 frames never arrived"), logged[0])
    }

    // MARK: S3

    func testAStreamPastFiveMinutesEndsWithAnError() async throws {
        var called = false
        api.voice.transcribeAudio = { _, _, _ in called = true; return "long" }
        start()
        let frame = pcm(ArraySlice(repeating: 5, count: VoiceWire.frameSamples))
        // Five minutes and one second.
        for seq in 0..<3_010 { voice.receive(binary: VoiceWire.audioFrame(seq: UInt32(seq), pcm: frame)) }
        end()
        try await Task.sleep(for: .milliseconds(50))
        let errors = messages.filter { if case .error = $0 { return true } else { return false } }
        XCTAssertEqual(errors.count, 1, "one voice.error, not one per extra frame")
        guard case .error(let id, _)? = errors.first else { return XCTFail() }
        XCTAssertEqual(id, "v1")
        XCTAssertFalse(called)
        XCTAssertNil(transcript())
    }

    func testTheBufferTakesThreeThousandFramesAndRefusesTheNext() {
        var buffer = VoiceStreamBuffer()
        let frame = Data(count: VoiceWire.frameBytes)
        for seq in 0..<UInt32(VoiceWire.maxFrames) { XCTAssertEqual(buffer.add(seq: seq, pcm: frame), .stored) }
        XCTAssertEqual(buffer.add(seq: UInt32(VoiceWire.maxFrames), pcm: frame), .tooLong)
        XCTAssertEqual(buffer.add(seq: 0, pcm: frame), .duplicate)
        var fresh = VoiceStreamBuffer()
        XCTAssertEqual(fresh.add(seq: 0, pcm: Data([1])), .malformed)
        XCTAssertEqual(VoiceWire.maxFrames * VoiceWire.frameSamples, 300 * VoiceWire.sampleRate, "five minutes")
    }

    // MARK: S4

    /// A short first sentence, then two sentences that are too long to share a chunk.
    private let reply = "The build is done. The tests in the Mac suite all passed on the first run, which is not what the reviewer expected to see today. "
        + "The iPhone suite also passed after the new mic code went in, and the screenshots for the pull request are ready to look at."

    func testAFinishedTurnIsSpokenToTheDeviceChunkByChunk() async throws {
        var synthesized: [String] = []
        api.voice.synthesize = { text in synthesized.append(text); return Data("wav-\(synthesized.count)".utf8) }
        XCTAssertEqual(SpeechText.chunks(of: reply).count, 3)
        voice.receive(text: VoiceClientMessage.ttsEnable(true).json)
        try finishTurn(reply)
        await wait("tts.end") { messages.contains { if case .ttsEnd = $0 { return true } else { return false } } }
        let chunks = messages.compactMap { message -> (String, Int, Bool)? in
            if case .ttsChunk(let reply, let index, let last) = message { return (reply, index, last) } else { return nil }
        }
        XCTAssertEqual(chunks.map(\.1), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.2), [false, false, true])
        XCTAssertEqual(Set(chunks.map(\.0)).count, 1)
        // Each tts.chunk message is followed by its audio.
        var order: [String] = []
        for output in out {
            switch output {
            case .text(let text): if case .ttsChunk(_, let index, _)? = VoiceServerMessage.parse(text) { order.append("chunk\(index)") } else { order.append("end") }
            case .binary(let data): order.append("audio\(try XCTUnwrap(VoiceWire.parseTTSFrame(data)).index)")
            }
        }
        XCTAssertEqual(order, ["chunk0", "audio0", "chunk1", "audio1", "chunk2", "audio2", "end"])
        XCTAssertFalse(api.voice.status.speaking, "nothing played on this Mac")
    }

    func testRepliesAreOffUntilThePhoneAsks() async throws {
        api.voice.synthesize = { _ in Data([1]) }
        try finishTurn(reply)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(out.isEmpty)
    }

    func testAnotherDevicesTurnIsNotSpoken() async throws {
        api.voice.synthesize = { _ in Data([1]) }
        voice.receive(text: VoiceClientMessage.ttsEnable(true).json)
        try finishTurn(reply, from: ChatOrigin.ios(device: "someone-else"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(out.isEmpty)
    }

    func testStopAfterTheFirstChunkStartsNoFurtherSynthesis() async throws {
        var synthesized: [String] = []
        var gate: CheckedContinuation<Void, Never>?
        api.voice.synthesize = { text in
            synthesized.append(text)
            // The second chunk waits, so the stop arrives while it is being made.
            if synthesized.count == 2 { await withCheckedContinuation { gate = $0 } }
            return Data([1, 2, 3])
        }
        voice.receive(text: VoiceClientMessage.ttsEnable(true).json)
        try finishTurn(reply)
        await wait("the first chunk") { messages.contains { if case .ttsChunk(_, 0, _) = $0 { return true } else { return false } } }
        await wait("the second synthesis") { gate != nil }
        voice.receive(text: VoiceClientMessage.ttsStop.json)
        gate?.resume()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(synthesized.count, 2, "the third chunk was never started")
        XCTAssertEqual(messages.filter { if case .ttsChunk = $0 { return true } else { return false } }.count, 1)
        XCTAssertFalse(messages.contains { if case .ttsEnd = $0 { return true } else { return false } })
    }

    func testTheMacsQuietSettingDoesNotSilenceThePhone() async throws {
        api.voice.synthesize = { _ in Data([1]) }
        voice.receive(text: VoiceClientMessage.ttsEnable(true).json)
        try finishTurn("One short reply.")
        await wait("tts.end") { messages.contains { if case .ttsEnd = $0 { return true } else { return false } } }
    }

    // MARK: Read aloud (tts.speak)

    private func chunks() -> [(reply: String, index: Int)] {
        messages.compactMap { if case .ttsChunk(let reply, let index, _) = $0 { return (reply, index) } else { return nil } }
    }

    private func errors() -> [String] {
        messages.compactMap { if case .error(_, let message) = $0 { return message } else { return nil } }
    }

    func testASpeakRequestReadsThatMessageWithSpokenRepliesOff() async throws {
        var synthesized: [String] = []
        api.voice.synthesize = { text in synthesized.append(text); return Data([1, 2]) }
        let item = ChatItem(kind: .assistant(reply))
        session.items = [ChatItem(kind: .user("question")), item]
        voice.receive(text: VoiceClientMessage.ttsSpeak(item: item.id.uuidString).json)
        await wait("tts.end") { messages.contains { if case .ttsEnd = $0 { return true } else { return false } } }
        XCTAssertEqual(chunks().map(\.index), [0, 1, 2])
        XCTAssertEqual(Set(chunks().map(\.reply)), [item.id.uuidString], "the reply id is the message id, so the phone can match its button")
        XCTAssertEqual(messages.last, .ttsEnd(reply: item.id.uuidString))
        XCTAssertEqual(synthesized.count, 3)
        XCTAssertFalse(api.voice.status.speaking, "nothing played on this Mac")
    }

    func testASpeakRequestForAMessageThatIsNotAReplyIsRefused() async throws {
        api.voice.synthesize = { _ in Data([1]) }
        let user = ChatItem(kind: .user("question"))
        session.items = [user]
        voice.receive(text: VoiceClientMessage.ttsSpeak(item: user.id.uuidString).json)
        await wait("the error") { !errors().isEmpty }
        XCTAssertTrue(chunks().isEmpty)
        XCTAssertEqual(messages.last, .ttsEnd(reply: user.id.uuidString), "the phone's button resets")
    }

    func testASpeakRequestForAnUnknownOrMalformedIdIsRefused() async throws {
        api.voice.synthesize = { _ in Data([1]) }
        session.items = []
        let unknown = UUID().uuidString
        voice.receive(text: VoiceClientMessage.ttsSpeak(item: unknown).json)
        await wait("the error") { !errors().isEmpty }
        XCTAssertEqual(messages.last, .ttsEnd(reply: unknown))
        out = []
        voice.receive(text: VoiceClientMessage.ttsSpeak(item: "../../etc/passwd").json)
        await wait("the second error") { !errors().isEmpty }
        XCTAssertTrue(chunks().isEmpty)
    }

    func testStopCancelsAReadRequest() async throws {
        var synthesized = 0
        var gate: CheckedContinuation<Void, Never>?
        api.voice.synthesize = { _ in
            synthesized += 1
            if synthesized == 2 { await withCheckedContinuation { gate = $0 } }
            return Data([1])
        }
        let item = ChatItem(kind: .assistant(reply))
        session.items = [item]
        voice.receive(text: VoiceClientMessage.ttsSpeak(item: item.id.uuidString).json)
        await wait("the second synthesis") { gate != nil }
        voice.receive(text: VoiceClientMessage.ttsStop.json)
        gate?.resume()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(synthesized, 2)
        XCTAssertFalse(messages.contains { if case .ttsEnd = $0 { return true } else { return false } })
    }

    /// Ends a turn the way the chat does, through the listeners `ChatAPI` keeps.
    private func finishTurn(_ answer: String, from origin: ChatOrigin? = nil) throws {
        let sender = origin ?? ChatOrigin.ios(device: device)
        session.onTurn?(sender, .finished(answer))
    }
}
