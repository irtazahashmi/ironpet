import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class ChatSpeechTests: XCTestCase {
    private var session: ChatSession!
    private var h: ChatHarness!
    private var deliver: [(AgentEvent) -> Void] = []
    /// The turns the agent received, in order.
    private var turns: [ACPTurn] = []
    /// What was sent to the speech server, in order.
    private var spoken: [String] = []

    override func setUp() async throws {
        TestMemory.isolate()
        h = ChatHarness(); session = h.session
        session.workspace = FileManager.default.temporaryDirectory
        deliver = []
        turns = []
        spoken = []
        session.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
        session.speech.isEnabled = { true }
        // Recorded, then cut short, so no audio device is needed.
        session.player.synthesize = { [unowned self] text in
            spoken.append(text)
            throw CancellationError()
        }
    }

    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    private func say(_ text: String) async {
        await h.model.sendSpokenNow(text)
        await settle()
    }

    private func type(_ text: String) async {
        h.model.input = text
        await h.model.sendNow()
        await settle()
    }

    private func answer(_ index: Int, _ text: String, error: String? = nil) async {
        await settle()
        deliver[index](.assistant(text))
        deliver[index](.finished(error: error))
        await settle()
    }

    private func lastReply() throws -> ChatSession.Item {
        try XCTUnwrap(session.items.last { if case .assistant = $0.kind { true } else { false } })
    }

    // MARK: A spoken message is a normal user message in the chat

    func testSpokenMessageIsAUserMessageMarkedAsVoice() async throws {
        await type("first typed")
        await answer(0, "Typed answer.")
        await say("what changed?")
        let user = try XCTUnwrap(session.items.last { if case .user("what changed?") = $0.kind { true } else { false } })
        XCTAssertEqual(user.origin, ChatSession.voiceOrigin)
        XCTAssertNil(session.items.first { if case .user("first typed") = $0.kind { true } else { false } }?.origin)
        XCTAssertFalse(session.items.contains { $0.origin == ChatSession.voiceOrigin && $0.id != user.id })
    }

    // MARK: The spoken summary

    func testReplyToASpokenMessageSpeaksOnlyItsSummary() async throws {
        await say("what changed?")
        await answer(0, "Two files changed.\n\nThe details are in [the diff](https://example.com/d):\n\n- `a.swift`\n- `b.swift`")
        XCTAssertEqual(spoken, ["Two files changed."])
        let reply = try lastReply()
        guard case .assistant(let text) = reply.kind else { return XCTFail("no reply") }
        XCTAssertEqual(text, "Two files changed.\n\nThe details are in [the diff](https://example.com/d):\n\n- `a.swift`\n- `b.swift`",
                       "the chat keeps the summary line and the full answer in one message")
        XCTAssertEqual(session.items.filter { if case .assistant = $0.kind { true } else { false } }.count, 1)
    }

    func testSummaryIsSpokenAsSoonAsItsLineIsComplete() async {
        await say("what changed?")
        await settle()
        deliver[0](.assistant("Two files"))
        await settle()
        XCTAssertEqual(spoken, [], "the line is not complete yet")
        deliver[0](.assistant(" changed.\n"))
        await settle()
        XCTAssertEqual(spoken, ["Two files changed."], "spoken while the rest of the reply is still being written")
        deliver[0](.assistant("\nThe full answer follows."))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertEqual(spoken, ["Two files changed."], "the summary is read once")
    }

    func testAOneLineReplyIsItsOwnSummaryWhenTheTurnEnds() async {
        await say("status?")
        await answer(0, "All green.")
        XCTAssertEqual(spoken, ["All green."])
    }

    func testTheAgentIsToldToStartWithASummary() async {
        await say("status?")
        XCTAssertTrue(turns[0].prompt.hasSuffix(SpokenSummary.note))
        XCTAssertTrue(turns[0].prompt.hasPrefix("status?"))
        let stored = session.items.compactMap { item -> String? in if case .user(let text) = item.kind { text } else { nil } }
        XCTAssertEqual(stored, ["status?"], "the stored message does not carry the note")
    }

    func testSummaryParsing() {
        XCTAssertEqual(SpokenSummary.summary(in: "\n  Done.\nMore.", final: false), "Done.")
        XCTAssertNil(SpokenSummary.summary(in: "Still writing", final: false))
        XCTAssertEqual(SpokenSummary.summary(in: "Still writing", final: true), "Still writing")
        XCTAssertNil(SpokenSummary.summary(in: "   \n  ", final: true))
        let long = String(repeating: "This sentence runs on. ", count: 30)
        let summary = SpokenSummary.summary(in: long + "\nBody", final: false)
        XCTAssertEqual(summary, "This sentence runs on. This sentence runs on.", "an overlong first line is cut to two sentences")
    }

    // MARK: Speak replies: Automatic, Always, Never

    func testTypedMessageAfterASpokenOneIsNotSpokenInAutomatic() async {
        await say("what changed?")
        await answer(0, "Two files changed.\n\nDetails.")
        XCTAssertEqual(spoken, ["Two files changed."])
        await type("and the tests?")
        XCTAssertFalse(turns[1].prompt.contains(SpokenSummary.note), "no summary is asked for when nothing is read")
        await answer(1, "They pass.")
        XCTAssertEqual(spoken, ["Two files changed."], "speech output received nothing for the typed turn")
    }

    func testAlwaysSpeaksTheSummaryOfATypedMessage() async {
        session.speakRepliesSetting = { .always }
        await type("what changed?")
        XCTAssertTrue(turns[0].prompt.hasSuffix(SpokenSummary.note))
        await answer(0, "Two files changed.\n\nDetails.")
        XCTAssertEqual(spoken, ["Two files changed."])
    }

    func testNeverSpeaksNothingButTheMessageAndReplyStillShow() async throws {
        session.speakRepliesSetting = { .never }
        await say("what changed?")
        XCTAssertFalse(turns[0].prompt.contains(SpokenSummary.note))
        await answer(0, "Two files changed.\n\nDetails.")
        XCTAssertEqual(spoken, [])
        XCTAssertTrue(session.items.contains { if case .user("what changed?") = $0.kind { true } else { false } })
        guard case .assistant(let text) = try lastReply().kind else { return XCTFail("no reply") }
        XCTAssertEqual(text, "Two files changed.\n\nDetails.")
    }

    func testPolicyByOriginAndSetting() {
        typealias S = Config.SpeakReplies
        XCTAssertTrue(S.automatic.speaks(afterSpokenMessage: true))
        XCTAssertFalse(S.automatic.speaks(afterSpokenMessage: false))
        XCTAssertTrue(S.always.speaks(afterSpokenMessage: true))
        XCTAssertTrue(S.always.speaks(afterSpokenMessage: false))
        XCTAssertFalse(S.never.speaks(afterSpokenMessage: true))
        XCTAssertFalse(S.never.speaks(afterSpokenMessage: false))
    }

    // MARK: One conversation

    func testSpokenTypedSpokenShareOneSessionAndThread() async throws {
        await say("one")
        await settle()
        deliver[0](.session("agent-session"))
        await answer(0, "First.\n\nFirst in full.")
        let thread = try XCTUnwrap(session.threadID)
        await type("two")
        await answer(1, "Second.")
        await say("three")
        await answer(2, "Third.\n\nThird in full.")
        XCTAssertEqual(turns.map(\.resume), [nil, "agent-session", "agent-session"], "every turn resumes the same agent session")
        XCTAssertEqual(session.threadID, thread)
        let users = session.items.compactMap { item -> (String, String?)? in if case .user(let text) = item.kind { (text, item.origin) } else { nil } }
        XCTAssertEqual(users.map(\.0), ["one", "two", "three"], "all three are in one transcript")
        XCTAssertEqual(users.map(\.1), [ChatSession.voiceOrigin, nil, ChatSession.voiceOrigin])
        XCTAssertEqual(spoken, ["First.", "Third."])
    }

    // MARK: What stays as it was

    func testTelegramAndAutomationRepliesAreNotRead() async {
        session.speakRepliesSetting = { .always }
        session.submit("status?", from: .telegram(chat: 42))
        await answer(0, "All green.")
        XCTAssertTrue(session.submitFromAutomation("check CI", automation: "ci"))
        await answer(1, "CI passed.")
        XCTAssertEqual(spoken, [])
        XCTAssertFalse(turns[0].prompt.contains(SpokenSummary.note))
    }

    func testQuietDuringACall() async {
        session.isQuiet = { true }
        await say("status?")
        await answer(0, "All green.")
        XCTAssertEqual(spoken, [])
    }

    func testOffNeverAsksWhetherItIsQuiet() async {
        var quietChecks = 0
        session.isQuiet = { quietChecks += 1; return false }
        session.speech.isEnabled = { false }
        await say("status?")
        await answer(0, "All green.")
        XCTAssertEqual(spoken, [])
        XCTAssertEqual(quietChecks, 0, "the quiet check polls the microphone list, so it must not run while off")
    }

    func testFailedTurnIsNotRead() async {
        await say("status?")
        await answer(0, "Partial", error: "agent crashed")
        XCTAssertEqual(spoken, [])
    }

    func testQueuedSpokenMessageKeepsItsMarkAndIsReadWhenItsTurnEnds() async {
        await type("first")
        await say("then this")
        XCTAssertEqual(session.queue.count, 1)
        await answer(0, "First answer.")
        XCTAssertEqual(spoken, [], "the typed turn is not read in Automatic")
        await answer(1, "Second answer.")
        XCTAssertEqual(spoken, ["Second answer."])
    }

    func testSpeakerButtonReadsAnyReplyInFull() async throws {
        session.speakRepliesSetting = { .never }
        await type("status?")
        await answer(0, "All green.\n\nEverything passed.")
        XCTAssertEqual(spoken, [])
        session.toggleSpeech(try lastReply())
        await settle()
        XCTAssertEqual(spoken, ["All green."], "the first chunk of the whole reply")
    }

    func testButtonShowsWithNeverAndAModel() {
        var speech = Config.Speech()
        speech.speakReplies = .never
        XCTAssertTrue(speech.canSpeak, "the default Kokoro model counts")
        speech.model = "  "
        XCTAssertFalse(speech.canSpeak)
    }

    func testFailedRequestShowsTheSpeechError() async {
        struct Down: LocalizedError { var errorDescription: String? { "voice server unreachable" } }
        session.speech.isEnabled = { false }
        session.player.synthesize = { _ in throw Down() }
        session.toggleSpeech(.init(kind: .assistant("Hello there.")))
        await settle()
        XCTAssertTrue(session.items.contains { if case .error("voice server unreachable") = $0.kind { true } else { false } })
        XCTAssertNil(session.speech.speakingID)
    }

    func testSendingStopsSpeech() async {
        session.player.synthesize = { _ in try await Task.sleep(nanoseconds: 10_000_000_000); return Data() }
        let item = ChatSession.Item(kind: .assistant("Long reply."))
        session.toggleSpeech(item)
        XCTAssertEqual(session.speech.speakingID, item.id)
        await type("interrupting")
        XCTAssertNil(session.speech.speakingID)
    }
}
