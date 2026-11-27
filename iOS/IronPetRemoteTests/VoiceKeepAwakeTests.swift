import XCTest
import IronPetKit
@testable import IronPetRemote

@MainActor
private final class FakeApp: IdleTimerControl {
    var isIdleTimerDisabled: Bool { didSet { history.append(isIdleTimerDisabled) } }
    var history: [Bool] = []
    init(_ value: Bool) { isIdleTimerDisabled = value }
}

private final class QuietChannel: VoiceChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var binaries = 0
    private let stream: AsyncThrowingStream<VoiceInbound, Error>
    private let continuation: AsyncThrowingStream<VoiceInbound, Error>.Continuation

    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }

    var sentTexts: [String] { lock.withLock { texts } }
    var binaryCount: Int { lock.withLock { binaries } }
    func send(text: String) async throws { lock.withLock { texts.append(text) } }
    func send(binary: Data) async throws { lock.withLock { binaries += 1 } }
    func incoming() -> AsyncThrowingStream<VoiceInbound, Error> { stream }
    func close() { continuation.finish() }

    func sent(_ matches: (VoiceClientMessage) -> Bool) -> Bool {
        sentTexts.contains { VoiceClientMessage.parse($0).map(matches) ?? false }
    }
}

@MainActor
private final class QuietEngine: ClipEngine {
    var onFailure: (@MainActor (String) -> Void)?
    func play(_ wav: Data, onFinish: @escaping @MainActor () -> Void) throws {}
    func stop() {}
}

/// One second of tone at start, then waits. `interrupt()` plays what a call does to the real mic: the stream ends, then the model hears why.
private final class CallMic: MicSource, @unchecked Sendable {
    private var finish: () -> Void = {}
    var onFailure: (@Sendable (String) -> Void)?
    var onInterrupted: (@Sendable (String) -> Void)?
    let tone: Bool

    init(tone: Bool = true) { self.tone = tone }

    func start() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        finish = { continuation.finish() }
        if tone { continuation.yield(Data(repeating: 7, count: 32_000)) }
        return stream
    }

    func stop() { finish() }

    func interrupt() {
        finish()
        onInterrupted?("Another app or a call took over the microphone.")
    }
}

/// The screen stays on while a voice message is recorded or a reply is read aloud, and the idle timer returns to its earlier value.
@MainActor
final class VoiceKeepAwakeTests: XCTestCase {
    private func poll(_ timeout: Double = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func rig(app: FakeApp, mic: CallMic = CallMic(), sendAtOnce: Bool = true) -> (voice: VoiceModel, channel: QuietChannel) {
        let channel = QuietChannel()
        let voice = VoiceModel(
            player: ReplyPlayer(engine: QuietEngine()),
            defaults: UserDefaults(suiteName: "voice-awake-\(UUID().uuidString)")!,
            openChannel: { channel },
            makeMic: { mic },
            idleTimer: app)
        voice.sendAtOnce = sendAtOnce
        return (voice, channel)
    }

    /// S1: the timer is off for the whole recording, however long, and nothing in the model turns it back on early.
    func testIdleTimerStaysDisabledWhileRecording() async {
        let app = FakeApp(false)
        let (voice, _) = rig(app: app)
        await voice.micTapped()
        XCTAssertEqual(voice.state, .recording)
        XCTAssertTrue(app.isIdleTimerDisabled)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(app.isIdleTimerDisabled)
        XCTAssertEqual(app.history, [true], "set once, never toggled while recording")
    }

    /// S4, sent path.
    func testIdleTimerRestoredAfterSend() async {
        let app = FakeApp(false)
        let (voice, _) = rig(app: app)
        await voice.micTapped()
        await voice.micTapped()
        XCTAssertFalse(app.isIdleTimerDisabled)
        XCTAssertEqual(app.history, [true, false])
    }

    /// S4, discarded path.
    func testIdleTimerRestoredAfterCancel() async {
        let app = FakeApp(false)
        let (voice, _) = rig(app: app)
        await voice.micTapped()
        XCTAssertTrue(app.isIdleTimerDisabled)
        await voice.cancelRecording()
        XCTAssertFalse(app.isIdleTimerDisabled)
    }

    /// S4: restored to the previous value, not to false.
    func testIdleTimerRestoredToPreviousValue() async {
        let app = FakeApp(true)
        let (voice, _) = rig(app: app)
        await voice.micTapped()
        await voice.cancelRecording()
        XCTAssertTrue(app.isIdleTimerDisabled)
    }

    /// S3 and S4: the timer is off while a reply arrives or plays, and restored when it ends.
    func testIdleTimerDisabledWhileSpeaking() async {
        let app = FakeApp(false)
        let (voice, _) = rig(app: app)
        voice.player.begin(reply: "item-1")
        XCTAssertTrue(voice.speaking)
        XCTAssertTrue(app.isIdleTimerDisabled)
        voice.player.finish(reply: "item-1")
        XCTAssertFalse(voice.speaking)
        XCTAssertFalse(app.isIdleTimerDisabled)
    }

    /// S4: a reply that is stopped also gives the timer back.
    func testIdleTimerRestoredWhenReplyStopped() async {
        let app = FakeApp(false)
        let (voice, _) = rig(app: app)
        voice.player.begin(reply: "item-1")
        voice.player.stop()
        XCTAssertFalse(app.isIdleTimerDisabled)
    }

    /// Recording while a reply plays keeps one hold: the timer goes back only after both end.
    func testIdleTimerHeldUntilBothEnd() async {
        let app = FakeApp(false)
        let (voice, _) = rig(app: app)
        voice.player.begin(reply: "item-1")
        await voice.micTapped()
        XCTAssertTrue(app.isIdleTimerDisabled)
        await voice.cancelRecording()
        voice.player.stop()
        XCTAssertFalse(app.isIdleTimerDisabled)
    }

    /// S5: a call during listening sends what was recorded and shows that the message was cut short.
    func testInterruptionSendsRecordedPart() async {
        let app = FakeApp(false)
        let mic = CallMic()
        let (voice, channel) = rig(app: app, mic: mic)
        await voice.micTapped()
        await poll { channel.binaryCount > 0 || voice.state != .recording }
        mic.interrupt()
        await poll { channel.sent { if case .end = $0 { return true } else { return false } } }
        XCTAssertTrue(channel.sent { if case .end = $0 { return true } else { return false } }, "the end message goes out, so the Mac transcribes the recorded part")
        XCTAssertFalse(channel.sent { if case .cancel = $0 { return true } else { return false } })
        XCTAssertEqual(voice.state, .transcribing)
        XCTAssertTrue(voice.errorMessage?.hasPrefix("Cut short") ?? false)
        XCTAssertFalse(app.isIdleTimerDisabled)
    }

    /// An interruption before any audio arrived drops the recording, as before.
    func testInterruptionWithNothingRecordedDrops() async {
        let app = FakeApp(false)
        let mic = CallMic(tone: false)
        let (voice, channel) = rig(app: app, mic: mic)
        await voice.micTapped()
        mic.interrupt()
        await poll { voice.state == .idle }
        XCTAssertEqual(voice.state, .idle)
        await poll { channel.sent { if case .cancel = $0 { return true } else { return false } } }
        XCTAssertTrue(channel.sent { if case .cancel = $0 { return true } else { return false } })
        XCTAssertFalse(app.isIdleTimerDisabled)
    }
}
