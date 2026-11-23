import AVFoundation
import IronPetKit
import XCTest
@testable import IronPetRemote

private func settle(_ timeout: Double = 10, _ condition: @escaping @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// What happened, in order, across the channel and the speaker.
@MainActor
private final class Log {
    var entries: [String] = []
}

private final class FakeChannel: VoiceChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var binaries: [Data] = []
    private let log: Log
    private let stream: AsyncThrowingStream<VoiceInbound, Error>
    private let continuation: AsyncThrowingStream<VoiceInbound, Error>.Continuation

    init(log: Log) {
        self.log = log
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    var sentTexts: [String] { lock.lock(); defer { lock.unlock() }; return texts }
    var sentBinaries: [Data] { lock.lock(); defer { lock.unlock() }; return binaries }

    var failTexts: (String) -> Bool = { _ in false }

    func send(text: String) async throws {
        if failTexts(text) { throw URLError(.notConnectedToInternet) }
        lock.lock(); texts.append(text); lock.unlock()
        let label = VoiceClientMessage.parse(text).map { "\($0)" } ?? text
        await MainActor.run { log.entries.append("send \(label)") }
    }

    func send(binary: Data) async throws {
        lock.lock(); binaries.append(binary); lock.unlock()
    }

    func incoming() -> AsyncThrowingStream<VoiceInbound, Error> { stream }
    func close() { continuation.finish() }
}

@MainActor
private final class FakeEngine: ClipEngine {
    let log: Log
    var finishCurrent: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    init(log: Log) { self.log = log }

    func play(_ wav: Data, onFinish: @escaping @MainActor () -> Void) throws {
        log.entries.append("engine.play \(wav.count)")
        finishCurrent = onFinish
    }

    func stop() {
        log.entries.append("engine.stop")
        finishCurrent = nil
    }
}

/// A microphone that hears nothing. Its stream ends when `stop()` is called, as the engine's does.
private final class SilentMic: MicSource {
    private var finish: () -> Void = {}
    private(set) var stopped = false
    var onFailure: (@Sendable (String) -> Void)?
    var startError: Error?

    func start() async throws -> AsyncStream<Data> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        finish = { continuation.finish() }
        return stream
    }

    func stop() {
        stopped = true
        finish()
    }
}

@MainActor
final class PhaseSixTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "phase6-\(UUID().uuidString)")! }

    /// One second of a 440 Hz tone as a stereo 44.1 kHz file, which is not the format the Mac wants.
    private func recording(seconds: Double = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-\(UUID().uuidString).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.5 }
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: S5

    func testARecordedFileStreamsAsFramesOf16KilohertzMono() async throws {
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { FileMicSource(url: url) })

        await model.micTapped()
        XCTAssertEqual(model.state, .recording)
        await settle { channel.sentBinaries.count >= 9 }
        await model.micTapped()
        XCTAssertEqual(model.state, .transcribing)

        let texts = channel.sentTexts
        guard case .start(let id, let mode)? = texts.first.flatMap(VoiceClientMessage.parse) else { return XCTFail("no voice.start in \(texts)") }
        XCTAssertEqual(mode, .draft)
        let format = try XCTUnwrap(texts.first.flatMap(VoiceClientMessage.declaredFormat))
        XCTAssertEqual(format.format, "pcm_s16le")
        XCTAssertEqual(format.rate, 16_000)
        XCTAssertEqual(format.channels, 1)
        XCTAssertEqual(texts.last.flatMap(VoiceClientMessage.parse), .end(id: id))

        let frames = try channel.sentBinaries.map { try XCTUnwrap(VoiceWire.parseAudioFrame($0)) }
        XCTAssertEqual(frames.map(\.seq), Array(0..<UInt32(frames.count)), "increasing seq from 0")
        XCTAssertTrue(frames.dropLast().allSatisfy { $0.pcm.count == VoiceWire.frameBytes }, "100 ms frames")
        XCTAssertTrue(frames.allSatisfy { $0.pcm.count % 2 == 0 && $0.pcm.count <= VoiceWire.frameBytes })
        let samples = frames.reduce(0) { $0 + $1.pcm.count / 2 }
        XCTAssertEqual(Double(samples), 16_000, accuracy: 800, "one second of audio at 16 kHz, not 44.1 kHz or stereo")
        // A tone, not silence.
        let loud = frames.dropFirst().first!.pcm.withUnsafeBytes { raw in (0..<raw.count / 2).map { abs(Int(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) }.max() ?? 0 }
        XCTAssertGreaterThan(loud, 5_000)
    }

    func testTheTranscriptGoesToTheComposerInDraftModeOnly() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        var heard: [(String, VoiceMode)] = []
        model.onTranscript = { heard.append(($0, $1)) }
        await model.micTapped()
        guard case .start(let id, _)? = channel.sentTexts.first.flatMap(VoiceClientMessage.parse) else { return XCTFail() }
        await model.micTapped()
        model.handle(.text(VoiceServerMessage.transcript(id: "other", text: "not mine").json))
        XCTAssertTrue(heard.isEmpty, "a transcript of another stream is ignored")
        model.handle(.text(VoiceServerMessage.transcript(id: id, text: "hello mac").json))
        XCTAssertEqual(heard.map(\.0), ["hello mac"])
        XCTAssertEqual(heard.map(\.1), [.draft])
        XCTAssertEqual(model.state, .idle)
    }

    func testSendAtOnceAsksForSendMode() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        model.sendAtOnce = true
        await model.micTapped()
        guard case .start(_, let mode)? = channel.sentTexts.first.flatMap(VoiceClientMessage.parse) else { return XCTFail() }
        XCTAssertEqual(mode, .send)
    }

    func testAMacErrorEndsTheRecordingWithItsMessage() async {
        let mic = SilentMic()
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { mic })
        await model.micTapped()
        guard case .start(let id, _)? = channel.sentTexts.first.flatMap(VoiceClientMessage.parse) else { return XCTFail() }
        model.handle(.text(VoiceServerMessage.error(id: id, message: "Voice input is off in Settings.").json))
        XCTAssertEqual(model.errorMessage, "Voice input is off in Settings.")
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(mic.stopped, "an error for the stream also stops the microphone")
    }

    func testCancellingARecordingStopsTheMicSendsCancelAndNeverEndsTheStream() async {
        let mic = SilentMic()
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { mic })
        model.onTranscript = { _, _ in XCTFail("a cancelled recording yields no text") }
        await model.micTapped()
        XCTAssertEqual(model.state, .recording)
        XCTAssertNotNil(model.startedAt)
        await model.cancelRecording()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(mic.stopped)
        let messages = channel.sentTexts.compactMap(VoiceClientMessage.parse)
        XCTAssertTrue(messages.contains { if case .cancel = $0 { true } else { false } })
        XCTAssertFalse(messages.contains { if case .end = $0 { true } else { false } }, "nothing is sent for transcription")
    }

    func testTheWaveformFollowsTheLevelOfTheAudio() {
        XCTAssertEqual(VoiceModel.level(of: Data(count: 640)), 0)
        var loud = Data()
        for _ in 0..<320 { withUnsafeBytes(of: Int16.max.littleEndian) { loud.append(contentsOf: $0) } }
        XCTAssertEqual(VoiceModel.level(of: loud), 1, accuracy: 0.001)
        var quiet = Data()
        for _ in 0..<320 { withUnsafeBytes(of: Int16(1000).littleEndian) { quiet.append(contentsOf: $0) } }
        XCTAssertEqual(VoiceModel.level(of: quiet), 0.175, accuracy: 0.01)
    }

    func testTheRecordingClockShowsMinutesAndSeconds() {
        XCTAssertEqual(VoiceClock.format(0), "0:00")
        XCTAssertEqual(VoiceClock.format(7), "0:07")
        XCTAssertEqual(VoiceClock.format(75), "1:15")
    }

    func testAMicrophoneThatDiesMidRecordingReturnsToIdleWithItsReason() async {
        let mic = SilentMic()
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { mic })
        await model.micTapped()
        XCTAssertEqual(model.state, .recording)
        mic.onFailure?("The audio route changed, so the microphone stopped.")
        await settle { model.state == .idle }
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.errorMessage, "The audio route changed, so the microphone stopped.")
        XCTAssertTrue(mic.stopped)
        await settle { channel.sentTexts.contains { VoiceClientMessage.parse($0).map { if case .cancel = $0 { true } else { false } } ?? false } }
        XCTAssertTrue(channel.sentTexts.compactMap(VoiceClientMessage.parse).contains { if case .cancel = $0 { true } else { false } }, "the Mac drops the stream")
    }

    func testAFailedEndOfStreamShowsAnErrorInsteadOfWaitingForever() async {
        let mic = SilentMic()
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { mic })
        await model.micTapped()
        channel.failTexts = { VoiceClientMessage.parse($0).map { if case .end = $0 { true } else { false } } ?? false }
        await model.micTapped()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.errorMessage, "The Mac is not reachable.")
    }

    func testADeniedMicrophoneShowsAMessageAndTheWayToSettings() async {
        let mic = SilentMic()
        mic.startError = MicError.denied
        let log = Log()
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { FakeChannel(log: log) }, makeMic: { mic })
        await model.micTapped()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.errorMessage, MicError.denied.errorDescription)
        XCTAssertTrue(model.needsSettings)
        mic.startError = nil
        await model.micTapped()
        XCTAssertFalse(model.needsSettings, "a new attempt clears the Settings offer")
    }

    func testAnAudioSessionFailureShowsItAndStaysIdle() async {
        let mic = SilentMic()
        mic.startError = MicError.unavailable("session could not start")
        let log = Log()
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { FakeChannel(log: log) }, makeMic: { mic })
        await model.micTapped()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.errorMessage, "The microphone is not available: session could not start")
        XCTAssertFalse(model.needsSettings)
    }

    func testAFifteenSecondRecordingStaysOnStopUntilTheUserTaps() async throws {
        let url = try recording(seconds: 15)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { FileMicSource(url: url) })
        await model.micTapped()
        await settle { channel.sentBinaries.count >= 149 }
        XCTAssertGreaterThanOrEqual(channel.sentBinaries.count, 149, "15 s is about 150 frames of 100 ms, the last still in the framer")
        XCTAssertEqual(model.state, .recording, "the audio running out does not end the recording")
        XCTAssertNil(model.errorMessage)
        await model.micTapped()
        XCTAssertEqual(model.state, .transcribing)
    }

    func testAMacThatNeverSendsTheTextEndsTheSpinnerWithAnError() async {
        VoiceModel.transcribeTimeout = .milliseconds(50)
        defer { VoiceModel.transcribeTimeout = .seconds(30) }
        let log = Log()
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { FakeChannel(log: log) }, makeMic: { SilentMic() })
        await model.micTapped()
        await model.micTapped()
        XCTAssertEqual(model.state, .transcribing)
        await settle { model.state == .idle }
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.errorMessage, "The Mac did not send the text back. Try again.")
    }

    // MARK: Read Aloud

    func testAClipThatDiesWhilePlayingShowsAnErrorAndDropsTheReply() async {
        let log = Log()
        let engine = FakeEngine(log: log)
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: engine), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        await model.toggleReading("r1")
        model.handle(.text(VoiceServerMessage.ttsChunk(reply: "r1", index: 0, last: false).json))
        model.handle(.binary(VoiceWire.ttsFrame(index: 0, wav: Data([1, 2]))))
        XCTAssertEqual(model.readingItem, "r1")
        engine.onFailure?("Another app or a call interrupted the reply.")
        XCTAssertEqual(model.errorMessage, "Another app or a call interrupted the reply.")
        XCTAssertFalse(model.speaking)
        XCTAssertNil(model.readingItem)
        model.handle(.text(VoiceServerMessage.ttsChunk(reply: "r1", index: 1, last: true).json))
        model.handle(.binary(VoiceWire.ttsFrame(index: 1, wav: Data([3]))))
        XCTAssertFalse(model.speaking, "the rest of a failed reply is dropped")
    }

    func testAReplyPlaysEveryClipUntilItEnds() async {
        let log = Log()
        let engine = FakeEngine(log: log)
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: engine), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        await model.toggleReading("r1")
        for index in 0..<3 {
            model.handle(.text(VoiceServerMessage.ttsChunk(reply: "r1", index: index, last: index == 2).json))
            model.handle(.binary(VoiceWire.ttsFrame(index: UInt32(index), wav: Data(repeating: 1, count: 10 + index))))
        }
        model.handle(.text(VoiceServerMessage.ttsEnd(reply: "r1").json))
        for _ in 0..<3 {
            XCTAssertTrue(model.speaking)
            engine.finishCurrent?()
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("engine.play") }, ["engine.play 10", "engine.play 11", "engine.play 12"])
        XCTAssertFalse(model.speaking)
        XCTAssertNil(model.errorMessage)
    }

    func testTheSocketClosingMidReplyShowsAnError() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        await model.toggleReading("r1")
        model.handle(.text(VoiceServerMessage.ttsChunk(reply: "r1", index: 0, last: false).json))
        model.handle(.binary(VoiceWire.ttsFrame(index: 0, wav: Data([1]))))
        channel.close()
        await settle { model.errorMessage != nil }
        XCTAssertEqual(model.errorMessage, "The connection to the Mac closed, so the reply stopped.")
        XCTAssertFalse(model.speaking)
    }

    // MARK: S6

    private func reply(_ model: VoiceModel, _ id: String, clips: Int) {
        for index in 0..<clips {
            model.handle(.text(VoiceServerMessage.ttsChunk(reply: id, index: index, last: index == clips - 1).json))
            model.handle(.binary(VoiceWire.ttsFrame(index: UInt32(index), wav: Data(repeating: UInt8(index), count: 10 + index))))
        }
    }

    func testTheMicStopsPlaybackBeforeTheMacIsToldToStop() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let engine = FakeEngine(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: engine), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        reply(model, "r1", clips: 3)
        XCTAssertEqual(log.entries, ["engine.play 10"], "the first clip plays, the others wait")
        XCTAssertTrue(model.speaking)

        await model.micTapped()

        let stop = log.entries.firstIndex(of: "engine.stop")
        let told = log.entries.firstIndex(of: "send ttsStop")
        XCTAssertNotNil(stop)
        XCTAssertNotNil(told)
        XCTAssertLessThan(stop ?? Int.max, told ?? 0, "playback stops before the tts.stop frame is sent: \(log.entries)")
        XCTAssertFalse(model.speaking)
        XCTAssertEqual(model.state, .recording)
    }

    func testClipsOfAStoppedReplyAreDropped() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        reply(model, "r1", clips: 1)
        await model.stopSpeaking()
        log.entries = []
        // The Mac had already sent the next clip when the stop reached it.
        model.handle(.text(VoiceServerMessage.ttsChunk(reply: "r1", index: 1, last: false).json))
        model.handle(.binary(VoiceWire.ttsFrame(index: 1, wav: Data([1]))))
        XCTAssertEqual(log.entries, [])
        // A new reply plays.
        reply(model, "r2", clips: 1)
        XCTAssertEqual(log.entries, ["engine.play 10"])
    }

    func testClipsPlayInOrderAndTheNextStartsWhenOneEnds() {
        let log = Log()
        let engine = FakeEngine(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: engine), defaults: defaults(), openChannel: { FakeChannel(log: log) }, makeMic: { SilentMic() })
        reply(model, "r1", clips: 3)
        model.handle(.text(VoiceServerMessage.ttsEnd(reply: "r1").json))
        XCTAssertTrue(model.speaking)
        engine.finishCurrent?()
        XCTAssertEqual(log.entries, ["engine.play 10", "engine.play 11"])
        engine.finishCurrent?()
        XCTAssertEqual(log.entries, ["engine.play 10", "engine.play 11", "engine.play 12"])
        engine.finishCurrent?()
        XCTAssertFalse(model.speaking)
    }

    func testTypingStopsAReplyThatPlays() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        reply(model, "r1", clips: 2)
        model.userTyped()
        await settle { log.entries.contains("send ttsStop") }
        XCTAssertEqual(Array(log.entries.suffix(2)), ["engine.stop", "send ttsStop"])
    }

    func testSpokenRepliesAreOffByDefaultAndRememberedOnce() {
        let store = defaults()
        let log = Log()
        let first = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: store, openChannel: { FakeChannel(log: log) }, makeMic: { SilentMic() })
        XCTAssertFalse(first.spokenReplies)
        first.spokenReplies = true
        let second = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: store, openChannel: { FakeChannel(log: log) }, makeMic: { SilentMic() })
        XCTAssertTrue(second.spokenReplies)
    }

    func testTurningSpokenRepliesOnTellsTheMac() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        model.spokenReplies = true
        await settle { channel.sentTexts.contains { VoiceClientMessage.parse($0) == .ttsEnable(true) } }
        XCTAssertTrue(channel.sentTexts.contains { VoiceClientMessage.parse($0) == .ttsEnable(true) })
    }

    // MARK: Read aloud

    func testTheSpeakerButtonAsksTheMacToReadThatMessage() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        XCTAssertFalse(model.spokenReplies, "it works with spoken replies off")
        await model.toggleReading("m1")
        XCTAssertEqual(channel.sentTexts.compactMap(VoiceClientMessage.parse), [.ttsSpeak(item: "m1")])
        XCTAssertEqual(model.readingItem, "m1", "the button shows Stop at once")
        XCTAssertTrue(model.speaking)
    }

    func testTheButtonShowsPlayingThenStopsWhenTheReplyEnds() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let engine = FakeEngine(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: engine), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        await model.toggleReading("m1")
        reply(model, "m1", clips: 1)
        XCTAssertEqual(model.readingItem, "m1")
        XCTAssertEqual(log.entries.filter { $0 == "engine.play 10" }.count, 1)
        model.handle(.text(VoiceServerMessage.ttsEnd(reply: "m1").json))
        engine.finishCurrent?()
        XCTAssertNil(model.readingItem)
        XCTAssertFalse(model.speaking)
    }

    func testTappingTheButtonOfTheReplyThatPlaysStopsItBeforeTellingTheMac() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        await model.toggleReading("m1")
        reply(model, "m1", clips: 2)
        log.entries = []
        await model.toggleReading("m1")
        XCTAssertEqual(log.entries, ["engine.stop", "send ttsStop"])
        XCTAssertNil(model.readingItem)
    }

    func testReadingAnotherReplyStopsTheFirstAndAsksForTheSecond() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        await model.toggleReading("m1")
        reply(model, "m1", clips: 2)
        log.entries = []
        await model.toggleReading("m2")
        XCTAssertEqual(log.entries, ["engine.stop", "send ttsStop", "send ttsSpeak(item: \"m2\")"])
        XCTAssertEqual(model.readingItem, "m2")
    }

    func testAReplyThatWasStoppedCanBeReadAgain() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        await model.toggleReading("m1")
        await model.toggleReading("m1")
        XCTAssertNil(model.readingItem)
        await model.toggleReading("m1")
        reply(model, "m1", clips: 1)
        XCTAssertEqual(model.readingItem, "m1")
        XCTAssertTrue(log.entries.contains("engine.play 10"), "clips of the new request are not dropped")
    }

    func testAMacThatNeverAnswersEndsTheButtonWithAnError() async {
        let log = Log()
        let channel = FakeChannel(log: log)
        let model = VoiceModel(player: ReplyPlayer(engine: FakeEngine(log: log)), defaults: defaults(), openChannel: { channel }, makeMic: { SilentMic() })
        let saved = VoiceModel.readTimeout
        VoiceModel.readTimeout = .milliseconds(50)
        defer { VoiceModel.readTimeout = saved }
        await model.toggleReading("m1")
        XCTAssertNotNil(model.readingItem)
        // A Mac without tts.speak never answers.
        await settle(5) { model.readingItem == nil }
        XCTAssertNil(model.readingItem)
        XCTAssertNotNil(model.errorMessage)
    }

    func testDictationLandsAfterTheDraftWithOneSpace() async throws {
        let server = MockIronPetServer()
        try server.start()
        defer { server.stop() }
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let chat = ChatModel(client: client, events: events, onUnauthorized: {})
        chat.insertDictation("first")
        XCTAssertEqual(chat.draft, "first")
        chat.insertDictation("  second\n")
        XCTAssertEqual(chat.draft, "first second")
        chat.insertDictation("   ")
        XCTAssertEqual(chat.draft, "first second")
    }
}
