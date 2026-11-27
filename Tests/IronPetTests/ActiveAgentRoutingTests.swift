import AppKit
import XCTest
@testable import IronPet
@testable import IronPetCore

/// Voice and speech follow the active agent: the transcript goes to its chat only, only its replies are spoken, a click on a pet selects
/// it, and exactly one pet shows the highlight.
@MainActor
final class ActiveAgentRoutingTests: XCTestCase {
    private var registry: AgentRegistry!
    private var speech: FakeSpeechOutput!
    private var one: ChatHarness!
    private var bunny: ChatHarness!
    private var bunnyID = ""
    private var hub: AgentChats!
    private var turns: [String: [ACPTurn]] = [:]
    private var deliver: [String: [(AgentEvent) -> Void]] = [:]

    override func setUp() async throws {
        TestMemory.isolate()
        registry = AgentRegistry(database: APITestSupport.memoryDatabase())
        bunnyID = try registry.create(name: "Bunny", agentCli: "claude").id
        speech = FakeSpeechOutput()
        speech.isEnabled = { true }
        turns = [:]
        deliver = [:]
        one = ChatHarness(session: ChatSession(restore: false, speech: speech))
        bunny = ChatHarness(session: ChatSession(restore: false, speech: speech, agentID: bunnyID))
        for (harness, id) in [(one!, AgentOwner.defaultID), (bunny!, bunnyID)] {
            harness.session.workspace = FileManager.default.temporaryDirectory
            // Always, so the typed transcripts here are read; the routing is what these tests are about.
            harness.session.speakRepliesSetting = { .always }
            harness.model.sendAfterDictation = true
            harness.session.turnRunner = { [unowned self] turn, onEvent in
                turns[id, default: []].append(turn)
                deliver[id, default: []].append(onEvent)
            }
        }
        hub = AgentChats(defaultChat: one.api, registry: registry, makeSession: { [unowned self] _ in bunny.session })
        let supervisor = AgentSupervisor(registry: registry, launcher: hub)
        supervisor.reconcile()
        addTeardownBlock { supervisor.stopAll() }
        one.session.speaksReplies = { [unowned self] in hub.speaksReplies(AgentOwner.defaultID) }
        bunny.session.speaksReplies = { [unowned self] in hub.speaksReplies(bunnyID) }
    }

    private func router() -> VoiceTranscriptRouter {
        VoiceTranscriptRouter(activeAgent: { [unowned self] in hub.activeAgentID },
                              model: { [unowned self] id in id == AgentOwner.defaultID ? one.model : id == bunnyID ? bunny.model : nil })
    }

    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    private func finish(_ id: String, _ text: String) async {
        await settle()
        deliver[id]?[0](.assistant(text))
        deliver[id]?[0](.finished(error: nil))
        await settle()
    }

    // MARK: S3, one transcript, one chat

    func testTheTranscriptGoesToTheActiveAgentsChatOnly() async throws {
        try hub.select(active: bunnyID)
        router().route("what is on my list?")
        await settle()
        XCTAssertEqual(turns[bunnyID]?.count, 1, "Bunny's chat got the text")
        XCTAssertNil(turns[AgentOwner.defaultID], "agent 1's chat got nothing")
        XCTAssertTrue(one.model.input.isEmpty)
    }

    func testWithOnlyAgentOneTheTranscriptGoesToAgentOne() async {
        XCTAssertEqual(router().target, AgentOwner.defaultID)
        router().route("hello")
        await settle()
        XCTAssertEqual(turns[AgentOwner.defaultID]?.count, 1)
        XCTAssertNil(turns[bunnyID])
    }

    func testAnActiveAgentWithNoChatOnScreenFallsBackToAgentOne() async {
        let lone = VoiceTranscriptRouter(activeAgent: { "agent_gone" }, model: { [unowned self] id in id == AgentOwner.defaultID ? one.model : nil })
        XCTAssertEqual(lone.target, AgentOwner.defaultID)
        lone.route("hello")
        await settle()
        XCTAssertEqual(turns[AgentOwner.defaultID]?.count, 1)
    }

    // MARK: S4, one voice

    func testOnlyTheActiveAgentsReplyIsSpokenAndSelectingAnotherMovesIt() async throws {
        try hub.select(active: bunnyID)
        one.model.receiveTranscript("status?")
        bunny.model.receiveTranscript("status?")
        await finish(AgentOwner.defaultID, "Agent one is done.")
        await finish(bunnyID, "Bunny is done.")
        XCTAssertEqual(speech.spoken.map(\.text), ["Bunny is done."], "agent 1's reply shows as text and is not spoken")
        XCTAssertTrue(one.session.items.contains { if case .assistant("Agent one is done.") = $0.kind { true } else { false } })

        try hub.select(active: AgentOwner.defaultID)
        deliver = [:]
        one.model.receiveTranscript("again?")
        bunny.model.receiveTranscript("again?")
        await finish(AgentOwner.defaultID, "One again.")
        await finish(bunnyID, "Bunny again.")
        XCTAssertEqual(speech.spoken.map(\.text), ["Bunny is done.", "One again."])
    }

    func testWithOnlyAgentOneItsReplyIsSpokenAsOnMain() async {
        let solo = AgentChats(defaultChat: one.api, registry: nil)
        one.session.speaksReplies = { solo.speaksReplies(AgentOwner.defaultID) }
        one.model.receiveTranscript("status?")
        await finish(AgentOwner.defaultID, "All good.")
        XCTAssertEqual(speech.spoken.map(\.text), ["All good."])
    }

    // MARK: S1 and S5, selecting and the highlight

    func testAClickOnAPetSelectsItsAgent() {
        let pet = PetController(store: SessionStore(), signals: SignalStore(), agentID: bunnyID, sprite: nil, offsetX: 0)
        pet.onChatToggle = {}
        pet.onSelected = { [unowned self] in try? hub.select(active: bunnyID) }
        XCTAssertEqual(hub.activeAgentID, AgentOwner.defaultID)
        pet.handleClick()
        XCTAssertEqual(hub.activeAgentID, bunnyID)
    }

    func testTheHighlightIsOnTheActivePetOnly() {
        let one = PetController(store: SessionStore(), signals: SignalStore())
        let two = PetController(store: SessionStore(), signals: SignalStore(), agentID: bunnyID, sprite: nil, offsetX: 0)
        for active in [AgentOwner.defaultID, bunnyID] {
            let lit = AgentPetSet.highlighted(active: active, onScreen: [AgentOwner.defaultID, bunnyID])
            one.isHighlighted = lit == AgentOwner.defaultID
            two.isHighlighted = lit == bunnyID
            XCTAssertEqual([one.isHighlighted, two.isHighlighted].filter { $0 }.count, 1)
            XCTAssertEqual(two.isHighlighted, active == bunnyID)
        }
        let lone = AgentPetSet.highlighted(active: AgentOwner.defaultID, onScreen: [AgentOwner.defaultID])
        one.isHighlighted = lone == AgentOwner.defaultID
        XCTAssertFalse(one.isHighlighted, "a single pet shows no highlight")
    }
}
