import XCTest
@testable import IronPet
@testable import IronPetCore
@testable import IronPetKit

@MainActor
private final class FakeMic: ConversationListening {
    var onEvent: ((ConversationMicEvent) -> Void)?
    let levels = LevelBuffer()
    private(set) var started = false
    private(set) var startCount = 0
    private(set) var stopped = false
    private(set) var cuts = 0

    func start() throws { started = true; startCount += 1 }
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
    private var sleeps: [TimeInterval] = []

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
        sleeps = []
        recorder.endPauseSeconds = { 2.5 }
        recorder.silenceSleep = { [unowned self] seconds in
            sleeps.append(seconds)
            try await withCheckedThrowingContinuation { (gate: CheckedContinuation<Void, Error>) in
                elapse = { [unowned self] in elapse = nil; gate.resume() }
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
        XCTAssertEqual(messages, [], "a short pause does not send yet")
        elapse?()
        await settle()
        XCTAssertEqual(messages, ["what changed in the last hour"])
        XCTAssertEqual(recorder.state, .waiting, "the conversation goes on while the reply is written")
        XCTAssertTrue(mic.stopped, "the microphone closes once the message is complete")
        XCTAssertEqual(ended, 0)
    }

    func testAShortPauseInTheMiddleKeepsOneMessage() async {
        await listen()
        mic.startTalking()
        mic.finishTalking("what changed")
        await settle()
        mic.startTalking()
        mic.finishTalking("in the last hour")
        await settle()
        XCTAssertEqual(messages, [])
        XCTAssertEqual(recorder.state, .listening)
        elapse?()
        await settle()
        XCTAssertEqual(messages, ["what changed in the last hour"])
    }

    func testTheMessageIsSentAfterTheConfiguredEndPause() async {
        recorder.endPauseSeconds = { 4 }
        await listen()
        mic.startTalking()
        mic.finishTalking("hello")
        await settle()
        XCTAssertEqual(sleeps.last, 4)
        elapse?()
        await settle()
        XCTAssertEqual(messages, ["hello"])
    }

    func testTheDefaultEndPauseIsTwoAndAHalfSeconds() {
        XCTAssertEqual(Config().voiceMode.endPauseSeconds, 2.5)
    }

    func testSecondPressAfterAPauseSendsEverythingSaidAtOnce() async {
        await listen()
        mic.startTalking()
        mic.finishTalking("one")
        await settle()
        recorder.press()
        await settle()
        XCTAssertEqual(messages, ["one"])
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

    func testSecondPressWhileSpeakingSendsEarlierUtterancesToo() async {
        await listen()
        mic.startTalking()
        mic.finishTalking("first")
        await settle()
        mic.startTalking()
        recorder.press()
        mic.finishTalking("second")
        await settle()
        XCTAssertEqual(messages, ["first second"])
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

    func testSilenceNeverEndsVoiceMode() async {
        await listen()
        await settle()
        XCTAssertTrue(sleeps.isEmpty, "no silence timer is armed")
        elapse?()
        await settle()
        XCTAssertEqual(recorder.state, .listening)
        XCTAssertEqual(ended, 0)
        await say("hello")
        recorder.turnEnded(failed: false)
        XCTAssertEqual(recorder.state, .listening)
        elapse?()
        await settle()
        XCTAssertEqual(recorder.state, .listening, "silence after a reply keeps listening too")
        XCTAssertEqual(ended, 0)
    }

    private func say(_ text: String) async {
        mic.startTalking()
        mic.finishTalking(text)
        await settle()
        elapse?()
        await settle()
    }

    func testListensAgainWhenTheSpokenSummaryEnds() async {
        var speaking = true
        recorder.isSpeaking = { speaking }
        await listen()
        await say("status?")
        XCTAssertEqual(recorder.state, .waiting)
        XCTAssertEqual(mic.startCount, 1)
        recorder.turnEnded(failed: false)
        XCTAssertEqual(recorder.state, .waiting, "the pet is still reading")
        XCTAssertEqual(mic.startCount, 1, "the microphone stays closed while the summary plays")
        recorder.speechEnded()
        XCTAssertEqual(recorder.state, .waiting, "still speaking")
        speaking = false
        recorder.speechEnded()
        XCTAssertEqual(recorder.state, .listening)
        XCTAssertEqual(mic.startCount, 2)
        XCTAssertEqual(ended, 0)
    }

    func testListensAgainAtOnceWhenTheReplyIsNotRead() async {
        await listen()
        await say("status?")
        recorder.turnEnded(failed: false)
        XCTAssertEqual(recorder.state, .listening)
        XCTAssertEqual(mic.startCount, 2)
    }

    func testTheNextMessageGoesOutAndIsFollowedByListeningAgain() async {
        await listen()
        await say("first")
        recorder.turnEnded(failed: false)
        await say("second")
        XCTAssertEqual(messages, ["first", "second"])
        XCTAssertEqual(recorder.state, .waiting)
        recorder.turnEnded(failed: false)
        XCTAssertEqual(recorder.state, .listening)
        XCTAssertEqual(mic.startCount, 3)
    }

    func testEscapeInAnyStateEndsVoiceModeForGood() async {
        recorder.isSpeaking = { true }
        await listen()
        await say("one")
        recorder.turnEnded(failed: false)
        recorder.cancel()
        XCTAssertEqual(recorder.state, .idle)
        recorder.isSpeaking = { false }
        recorder.speechEnded()
        recorder.turnEnded(failed: false)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(mic.startCount, 1)
        XCTAssertEqual(ended, 1)
        // While transcribing: nothing is sent and nothing resumes.
        recorder.transcribe = { _ in try await Task.sleep(for: .seconds(10)); return "late" }
        await listen()
        await say("two")
        XCTAssertEqual(recorder.state, .transcribing)
        recorder.cancel()
        recorder.turnEnded(failed: false)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(messages, ["one"])
    }

    func testAFailedTurnEndsVoiceMode() async {
        await listen()
        await say("one")
        recorder.turnEnded(failed: true)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(mic.startCount, 1)
    }

    func testACallStartingDuringTheReplyEndsVoiceMode() async {
        await listen()
        await say("one")
        recorder.quietReason = { "a call" }
        recorder.turnEnded(failed: false)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(failures, ["Stopped listening: a call started."])
        XCTAssertEqual(mic.startCount, 1)
    }

    func testAReplyWithNoSpokenMessageDoesNotStartListening() async {
        recorder.turnEnded(failed: false)
        recorder.speechEnded()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(mic.startCount, 0)
    }

    func testPressWhileWaitingListensAtOnce() async {
        recorder.isSpeaking = { true }
        await listen()
        await say("one")
        recorder.press()
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
        elapse?()
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
        elapse?()
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
        elapse?()
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
