import XCTest
@testable import IronPet
@testable import IronPetCore
@testable import IronPetKit

@MainActor
private final class FakeMic: ConversationListening {
    var onEvent: ((ConversationMicEvent) -> Void)?
    let levels = LevelBuffer()
    private(set) var started = false
    private(set) var stopped = false
    private(set) var cuts = 0

    func start() throws { started = true }
    func stop() { stopped = true }
    func cutNow() { cuts += 1 }

    func startTalking() { onEvent?(.speechStarted) }
    func finishTalking(_ text: String) { onEvent?(.utterance(Data(text.utf8))) }
}

@MainActor
final class SpokenMessageRecorderTests: XCTestCase {
    private var recorder: SpokenMessageRecorder!
    private var mic: FakeMic!
    private var messages: [String] = []
    private var failures: [String] = []
    private var started = 0
    private var ended = 0
    /// Silence timers fire when the test calls `elapse()`.
    private var elapse: (() -> Void)?

    override func setUp() async throws {
        recorder = SpokenMessageRecorder()
        mic = FakeMic()
        messages = []
        failures = []
        started = 0
        ended = 0
        recorder.microphoneAllowed = { true }
        recorder.makeMic = { [unowned self] in mic }
        recorder.transcribe = { wav in String(decoding: wav, as: UTF8.self) }
        recorder.silenceSeconds = { 20 }
        recorder.silenceSleep = { [unowned self] _ in
            try await withCheckedThrowingContinuation { (gate: CheckedContinuation<Void, Error>) in
                elapse = { gate.resume() }
            }
        }
        recorder.quietCheckInterval = 3600
        recorder.onMessage = { [unowned self] in messages.append($0) }
        recorder.onFailure = { [unowned self] in failures.append($0) }
        recorder.onStarted = { [unowned self] in started += 1 }
        recorder.onEnded = { [unowned self] in ended += 1 }
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func listen() async {
        recorder.press()
        await settle()
    }

    func testPressListensThenASilenceEndedUtteranceIsSentAsOneMessage() async {
        await listen()
        XCTAssertEqual(recorder.state, .listening)
        XCTAssertTrue(mic.started)
        XCTAssertEqual(started, 1)
        mic.startTalking()
        mic.finishTalking("what changed in the last hour")
        await settle()
        XCTAssertEqual(messages, ["what changed in the last hour"])
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(mic.stopped, "the microphone closes once the message is complete")
        XCTAssertEqual(ended, 1)
    }

    func testSecondPressWhileSpeakingEndsTheUtteranceAndSendsIt() async {
        await listen()
        mic.startTalking()
        recorder.press()
        XCTAssertEqual(mic.cuts, 1)
        mic.finishTalking("send this now")
        await settle()
        XCTAssertEqual(messages, ["send this now"])
    }

    func testSecondPressBeforeAnyWordDiscardsTheRecording() async {
        await listen()
        recorder.press()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(messages, [])
        XCTAssertTrue(mic.stopped)
    }

    func testEscapeDiscardsWhatWasSaid() async {
        await listen()
        mic.startTalking()
        recorder.cancel()
        mic.finishTalking("too late")
        await settle()
        XCTAssertEqual(messages, [])
        XCTAssertEqual(recorder.state, .idle)
    }

    func testNothingSaidEndsListeningAfterTheSilenceTime() async {
        await listen()
        await settle()
        elapse?()
        await settle()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(messages, [])
    }

    func testSpeakingKeepsListeningOpenPastTheSilenceTime() async {
        await listen()
        await settle()
        mic.startTalking()
        elapse?()
        await settle()
        XCTAssertEqual(recorder.state, .listening)
    }

    func testADiscardedBlipKeepsListening() async {
        await listen()
        mic.startTalking()
        mic.onEvent?(.discarded)
        await settle()
        XCTAssertEqual(recorder.state, .listening)
    }

    func testDuringACallItDoesNotListen() async {
        recorder.quietReason = { "a call" }
        await listen()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertFalse(mic.started)
        XCTAssertEqual(failures, ["Voice doesn't listen during a call."])
    }

    func testNoMicrophoneAccessIsReported() async {
        recorder.microphoneAllowed = { false }
        await listen()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(failures.first?.contains("Microphone") == true)
    }

    func testFailedTranscriptionIsReportedAndSendsNothing() async {
        struct Down: LocalizedError { var errorDescription: String? { "server down" } }
        recorder.transcribe = { _ in throw Down() }
        await listen()
        mic.startTalking()
        mic.finishTalking("hello")
        await settle()
        XCTAssertEqual(messages, [])
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(failures.first?.contains("server down") == true)
    }

    func testAnEmptyTranscriptSendsNothing() async {
        recorder.transcribe = { _ in "  " }
        await listen()
        mic.startTalking()
        mic.finishTalking("hello")
        await settle()
        XCTAssertEqual(messages, [])
        XCTAssertEqual(failures, ["I didn't catch that."])
    }

    func testPressWhileTranscribingDoesNothing() async {
        recorder.transcribe = { _ in try await Task.sleep(for: .seconds(10)); return "late" }
        await listen()
        mic.startTalking()
        mic.finishTalking("hello")
        await settle()
        XCTAssertEqual(recorder.state, .transcribing)
        recorder.press()
        XCTAssertEqual(recorder.state, .transcribing)
        recorder.cancel()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(messages, [])
    }

    func testTheMicrophoneFailingEndsListening() async {
        await listen()
        mic.onEvent?(.failed("The microphone stopped."))
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(failures, ["The microphone stopped."])
    }

    func testTheShortcutIsRegisteredOnlyWithVoiceNotesOn() {
        var config = Config()
        XCTAssertNil(SpokenMessageController.hotkey(in: config))
        config.voice.enabled = true
        XCTAssertEqual(SpokenMessageController.hotkey(in: config), "ctrl+shift+v")
        config.hotkeys.voiceMode = ""
        XCTAssertNil(SpokenMessageController.hotkey(in: config), "an empty shortcut turns it off")
    }

    func testJobUpdateWording() {
        var job = Job(id: "j1", title: "Fix the test", prompt: "p", folder: "/tmp", agent: "claude", model: nil, created: Date())
        job.state = .done
        job.summary = "Two files changed."
        XCTAssertEqual(SpokenMessageController.update(for: job), "Fix the test is done. Two files changed.")
        job.state = .running
        XCTAssertNil(SpokenMessageController.update(for: job))
    }
}
