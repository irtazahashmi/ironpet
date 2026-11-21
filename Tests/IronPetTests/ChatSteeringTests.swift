import XCTest
@testable import IronPet

/// A running turn that can take messages: queued rows become sent messages in order, and an approval holds them.
@MainActor
final class ChatSteeringTests: XCTestCase {
    private var session: ChatSession!
    private var h: ChatHarness!
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []
    /// What the agent received through steering, in order.
    private var steered: [String] = []
    private var outcome: ACPBackend.SteerOutcome = .delivered

    override func setUp() async throws {
        TestMemory.isolate()
        h = ChatHarness(); session = h.session
        turns = []; deliver = []; steered = []; outcome = .delivered
        session.workspace = FileManager.default.temporaryDirectory
        session.turnRunner = { [unowned self] turn, onEvent in turns.append(turn); deliver.append(onEvent) }
        session.steerRunner = { [unowned self] turn in steered.append(turn.prompt); return outcome }
    }

    private func settle() async { for _ in 0..<8 { await Task.yield() } }

    private func type(_ text: String) async {
        h.model.input = text
        await h.model.sendNow()
        await settle()
    }

    private var userTexts: [String] {
        session.items.compactMap { if case .user(let text) = $0.kind { text } else { nil } }
    }

    func testMessageTypedDuringATurnGoesIntoItAndBecomesASentMessage() async {
        await type("first")
        await type("also check the tests")
        XCTAssertEqual(steered, ["also check the tests"])
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(userTexts, ["first", "also check the tests"])
        XCTAssertEqual(turns.count, 1, "no second turn starts")
    }

    func testFiveMessagesWithTheThirdRemovedBeforeDeliveryArriveInOrder() async {
        session.steerRunner = { [unowned self] turn in
            steered.append(turn.prompt)
            await Task.yield()
            return .delivered
        }
        await type("start")
        // An open approval keeps all five queued, so one can be removed before delivery.
        session.handlePermission(ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "rm -rf build"])) { _ in }
        for n in 1...5 { await type("m\(n)") }
        XCTAssertEqual(session.queue.count, 5)
        session.removeQueued(session.queue[2].id)
        session.decide(session.approvals[0], allow: true)
        await settle()
        XCTAssertEqual(steered, ["m1", "m2", "m4", "m5"])
        XCTAssertEqual(userTexts, ["start", "m1", "m2", "m4", "m5"])
        XCTAssertTrue(session.queue.isEmpty)
    }

    func testAgentWithoutSteeringKeepsMessagesQueuedUntilTheTurnEnds() async {
        session.steerRunner = nil
        await type("first")
        await type("second")
        XCTAssertEqual(session.queue.map(\.text), ["second"])
        XCTAssertTrue(steered.isEmpty)
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(userTexts, ["first", "second"])
    }

    func testOpenApprovalHoldsTheMessageAndSaysSoUntilItIsAnswered() async {
        await type("first")
        session.handlePermission(ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "rm -rf build"])) { _ in }
        XCTAssertEqual(session.approvals.count, 1)
        await type("while you wait")
        XCTAssertEqual(session.queue.map(\.text), ["while you wait"])
        XCTAssertTrue(session.queueWaitsForAnswer)
        XCTAssertTrue(steered.isEmpty)
        session.decide(session.approvals[0], allow: true)
        await settle()
        XCTAssertEqual(steered, ["while you wait"])
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertFalse(session.queueWaitsForAnswer)
    }

    func testStopReturnsUndeliveredMessagesToTheDraft() async {
        await type("first")
        session.handlePermission(ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "rm -rf build"])) { _ in }
        await type("one")
        await type("two")
        session.stop()
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(session.takeRestoredDraft()?.text, "one\n\ntwo")
        XCTAssertTrue(steered.isEmpty)
    }

    func testMessageFromAnotherClientTakesTheSamePathAndHearsTheTurnEnd() async {
        var events: [ChatSession.TurnEvent] = []
        session.onTurn = { _, event in events.append(event) }
        await type("first")
        let phone = ChatOrigin(client: "ios", ref: "phone-1")
        session.submit("from the phone", from: phone)
        await settle()
        XCTAssertEqual(steered, ["from the phone"])
        XCTAssertTrue(session.queue.isEmpty)
        deliver[0](.assistant("done"))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertTrue(events.contains(.finished("done")), "the phone is told how the turn it joined ended")
    }

    func testRefusedSteerLeavesTheMessageQueuedForTheTurnEnd() async {
        outcome = .failed("nope")
        await type("first")
        await type("second")
        XCTAssertEqual(session.queue.map(\.text), ["second"])
        XCTAssertEqual(steered.count, 1, "no retry loop")
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(userTexts, ["first", "second"])
    }

    func testAutomationAndNoticesWaitForTheTurnEnd() async {
        await type("first")
        session.submitFromAutomation("check things", automation: "watcher")
        await settle()
        XCTAssertEqual(session.queue.count, 1)
        XCTAssertTrue(steered.isEmpty)
    }
}
