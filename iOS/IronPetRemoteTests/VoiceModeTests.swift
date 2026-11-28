import XCTest
import IronPetKit
@testable import IronPetRemote

private final class Channel: VoiceChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private let stream: AsyncThrowingStream<VoiceInbound, Error>
    private let continuation: AsyncThrowingStream<VoiceInbound, Error>.Continuation

    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }

    var messages: [VoiceClientMessage] { lock.withLock { texts.compactMap(VoiceClientMessage.parse) } }
    var ends: Int { messages.filter { if case .end = $0 { true } else { false } }.count }
    var cancels: Int { messages.filter { if case .cancel = $0 { true } else { false } }.count }

    func send(text: String) async throws { lock.withLock { texts.append(text) } }
    func send(binary: Data) async throws {}
    func incoming() -> AsyncThrowingStream<VoiceInbound, Error> { stream }
    func close() { continuation.finish() }
}

@MainActor
private final class SilentEngine: ClipEngine {
    var onFailure: (@MainActor (String) -> Void)?
    func play(_ wav: Data, onFinish: @escaping @MainActor () -> Void) throws {}
    func stop() {}
}

private final class Idle: IdleTimerControl {
    var isIdleTimerDisabled = false
}

/// A mic the test feeds by hand, so time is the length of the audio and not the wall clock.
private final class FakeMic: MicSource, @unchecked Sendable {
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var stopped = false
    var onFailure: (@Sendable (String) -> Void)?

    func start() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopped = true
        continuation?.finish()
    }

    /// `seconds` of a loud tone (`loud`) or silence, in 100 ms chunks.
    func feed(loud: Bool, seconds: Double) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            var pcm = Data()
            for _ in 0..<1_600 { withUnsafeBytes(of: Int16(loud ? 16_000 : 0).littleEndian) { pcm.append(contentsOf: $0) } }
            continuation?.yield(pcm)
        }
    }
}

/// Voice mode: one tap listens, the phone ends the message after a pause, and nothing partial is ever sent.
@MainActor
final class VoiceModeTests: XCTestCase {
    private func rig() -> (voice: VoiceModel, mic: FakeMic, channel: Channel, events: () -> [VoiceModel.SendEvent]) {
        let channel = Channel()
        let mic = FakeMic()
        let voice = VoiceModel(player: ReplyPlayer(engine: SilentEngine()), defaults: UserDefaults(suiteName: "voice-mode-\(UUID().uuidString)")!,
                               openChannel: { channel }, makeMic: { mic }, idleTimer: Idle())
        var events: [VoiceModel.SendEvent] = []
        voice.onSend = { events.append($0) }
        return (voice, mic, channel, { events })
    }

    private func poll(_ timeout: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func streamID(_ channel: Channel) -> String? {
        for case .start(let id, _) in channel.messages { return id }
        return nil
    }

    // S1
    func testThePhoneEndsTheStreamAfterThePauseAndSendsTheTranscript() async throws {
        let (voice, mic, channel, events) = rig()
        await voice.voiceModeTapped()
        XCTAssertTrue(voice.voiceModeOn)
        XCTAssertEqual(voice.state, .recording)
        mic.feed(loud: true, seconds: 1)
        mic.feed(loud: false, seconds: 2.0)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(channel.ends, 0, "the pause is shorter than 2.5 s")
        mic.feed(loud: false, seconds: 0.7)
        await poll { channel.ends == 1 }
        XCTAssertEqual(channel.ends, 1)
        XCTAssertTrue(mic.stopped)
        XCTAssertEqual(voice.state, .transcribing)
        XCTAssertTrue(voice.voiceModeOn)
        let id = try XCTUnwrap(streamID(channel))
        guard case .start(_, let mode)? = channel.messages.first else { return XCTFail("no voice.start") }
        XCTAssertEqual(mode, .send)
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "run the tests").json))
        XCTAssertTrue(events().contains(.transcribed(id: id, text: "run the tests")))
        XCTAssertEqual(voice.state, .idle)
    }

    // S2
    func testAShortPauseInTheMiddleOfASentenceDoesNotEndTheStream() async throws {
        let (voice, mic, channel, _) = rig()
        await voice.voiceModeTapped()
        mic.feed(loud: true, seconds: 1)
        mic.feed(loud: false, seconds: 1)
        mic.feed(loud: true, seconds: 1)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(channel.ends, 0)
        XCTAssertEqual(voice.state, .recording)
        mic.feed(loud: false, seconds: 3)
        await poll { channel.ends == 1 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(channel.ends, 1)
        XCTAssertEqual(channel.messages.filter { if case .start = $0 { true } else { false } }.count, 1)
    }

    // S3
    func testSilenceEndsTheTurnButVoiceModeKeepsListening() async throws {
        let (voice, mic, channel, events) = rig()
        voice.silence = 5
        await voice.voiceModeTapped()
        mic.feed(loud: false, seconds: 5.5)
        await poll { channel.cancels == 1 }
        await poll { channel.messages.filter { if case .start = $0 { true } else { false } }.count == 2 }
        XCTAssertEqual(channel.cancels, 1)
        XCTAssertEqual(channel.messages.filter { if case .start = $0 { true } else { false } }.count, 2, "a new turn started")
        XCTAssertTrue(voice.voiceModeOn)
        XCTAssertEqual(voice.state, .recording)
        XCTAssertEqual(channel.ends, 0)
        XCTAssertTrue(events().isEmpty)
    }

    func testAnEmptyTranscriptStartsTheNextTurn() async throws {
        let (voice, mic, channel, _) = rig()
        await voice.voiceModeTapped()
        mic.feed(loud: true, seconds: 1)
        mic.feed(loud: false, seconds: 3)
        await poll { channel.ends == 1 }
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "").json))
        await poll { voice.state == .recording }
        XCTAssertTrue(voice.voiceModeOn)
        XCTAssertEqual(voice.state, .recording)
    }

    func testAMessageSentWithRepliesSilentStartsTheNextTurn() async throws {
        let (voice, mic, channel, _) = rig()
        await voice.voiceModeTapped()
        mic.feed(loud: true, seconds: 1)
        mic.feed(loud: false, seconds: 3)
        await poll { channel.ends == 1 }
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "hello").json))
        await poll { voice.state == .recording }
        XCTAssertEqual(voice.state, .recording)
        XCTAssertTrue(voice.voiceModeOn)
    }

    func testTheControlEndsVoiceModeWhileTheMessageUploads() async throws {
        let (voice, mic, channel, _) = rig()
        await voice.voiceModeTapped()
        mic.feed(loud: true, seconds: 1)
        mic.feed(loud: false, seconds: 3)
        await poll { channel.ends == 1 }
        await voice.voiceModeTapped()
        XCTAssertFalse(voice.voiceModeOn)
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "hello").json))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(voice.state, .idle)
    }

    // S4
    func testTappingTheControlEndsVoiceModeWithoutSendingAnything() async throws {
        let (voice, mic, channel, events) = rig()
        await voice.voiceModeTapped()
        mic.feed(loud: true, seconds: 1)
        await voice.voiceModeTapped()
        XCTAssertEqual(voice.state, .idle)
        XCTAssertFalse(voice.voiceModeOn)
        XCTAssertTrue(mic.stopped)
        XCTAssertEqual(channel.ends, 0)
        XCTAssertEqual(channel.cancels, 1)
        XCTAssertTrue(events().isEmpty)
    }

    // S5
    func testTheMicButtonStillRecordsUntilTheSecondTapWithoutEndingByItself() async throws {
        let (voice, mic, channel, _) = rig()
        await voice.micTapped()
        XCTAssertFalse(voice.voiceModeOn)
        mic.feed(loud: true, seconds: 1)
        mic.feed(loud: false, seconds: 5)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(voice.state, .recording)
        XCTAssertEqual(channel.ends, 0)
        await voice.micTapped()
        XCTAssertEqual(channel.ends, 1)
    }

    // Replies on: the phone waits for the reply, and a reply with no audio ends the wait so it listens again.
    func testAfterAMessageWithRepliesOnThePhoneWaitsAndThenListensWhenTheReplyEndsWithoutAudio() async throws {
        let (voice, mic, channel, _) = rig()
        voice.spokenReplies = true
        await voice.voiceModeTapped()
        mic.feed(loud: true, seconds: 1)
        mic.feed(loud: false, seconds: 3)
        await poll { channel.ends == 1 }
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "hello").json))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(voice.state, .idle, "the reply has not come yet, so the mic stays closed")
        XCTAssertTrue(voice.voiceModeOn)
        voice.handle(.text(VoiceServerMessage.ttsEnd(reply: "r1").json))
        await poll { voice.state == .recording }
        XCTAssertEqual(voice.state, .recording)
    }

    func testAReplyThatPlaysResumesListeningOnlyWhenItsAudioHasEnded() async throws {
        let (voice, mic, channel, _) = rig()
        voice.spokenReplies = true
        await voice.voiceModeTapped()
        mic.feed(loud: true, seconds: 1)
        mic.feed(loud: false, seconds: 3)
        await poll { channel.ends == 1 }
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "hello").json))
        voice.handle(.text(VoiceServerMessage.ttsChunk(reply: "r1", index: 0, last: true).json))
        voice.handle(.binary(VoiceWire.ttsFrame(index: 0, wav: Data([1, 2, 3]))))
        voice.handle(.text(VoiceServerMessage.ttsEnd(reply: "r1").json))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(voice.speaking)
        XCTAssertEqual(voice.state, .idle, "the summary is still playing")
        voice.player.stop()
        await poll { voice.state == .recording }
        XCTAssertEqual(voice.state, .recording)
    }

    // S3
    func testVoiceModeKeepsListeningThroughRepeatedSilenceAndTurningItOffClosesTheMic() async throws {
        let (voice, mic, channel, _) = rig()
        voice.silence = 5
        await voice.voiceModeTapped()
        for round in 1...3 {
            mic.feed(loud: false, seconds: 5.5)
            await poll { channel.cancels == round }
        }
        await poll { voice.state == .recording }
        XCTAssertTrue(voice.voiceModeOn)
        XCTAssertEqual(voice.state, .recording)
        await voice.voiceModeTapped()
        XCTAssertFalse(voice.voiceModeOn)
        XCTAssertEqual(voice.state, .idle)
    }
}
