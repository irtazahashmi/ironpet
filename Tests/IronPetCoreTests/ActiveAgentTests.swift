import XCTest
@testable import IronPetCore

/// The active agent: the pet the user selected last. It starts as agent 1, survives a restart, falls back to agent 1 when it is disabled,
/// deleted or unknown, and decides which chat speaks its replies aloud.
@MainActor
final class ActiveAgentTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("ironpet.db") }

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-active-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func openRegistry() throws -> AgentRegistry {
        AgentRegistry(database: try Database(path: file, migrations: AppMigrations.all))
    }

    private func memoryRegistry() throws -> AgentRegistry {
        AgentRegistry(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    // MARK: S1, selecting and keeping the choice

    func testAgentOneIsActiveUntilAnotherIsSelected() async throws {
        let registry = try memoryRegistry()
        try registry.create(name: "Bunny", agentCli: "claude")
        XCTAssertEqual(registry.activeAgentID, AgentOwner.defaultID)
    }

    func testSelectingAnAgentMakesItActiveAndItSurvivesARestart() async throws {
        var registry: AgentRegistry? = try openRegistry()
        let bunny = try XCTUnwrap(registry?.create(name: "Bunny", agentCli: "claude"))
        try registry?.select(active: bunny.id)
        XCTAssertEqual(registry?.activeAgentID, bunny.id)
        registry = nil
        let reopened = try openRegistry()
        XCTAssertEqual(reopened.activeAgentID, bunny.id, "a new registry over the same file reads the stored choice")
    }

    func testSelectingAgentOneAgainMovesBack() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        try registry.select(active: bunny.id)
        try registry.select(active: AgentOwner.defaultID)
        XCTAssertEqual(registry.activeAgentID, AgentOwner.defaultID)
    }

    func testSelectingAnUnknownOrDisabledAgentThrowsAndKeepsTheChoice() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        let owl = try registry.create(name: "Owl", agentCli: "claude")
        try registry.update(owl.id, AgentRecordPatch(enabled: false))
        try registry.select(active: bunny.id)
        XCTAssertThrowsError(try registry.select(active: "agent_nobody"))
        XCTAssertThrowsError(try registry.select(active: owl.id))
        XCTAssertEqual(registry.activeAgentID, bunny.id)
    }

    func testSelectingTheActiveAgentAnnouncesNothing() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        try registry.select(active: bunny.id)
        var announced = 0
        let token = registry.activeChanges.observe { announced += 1 }
        try registry.select(active: bunny.id)
        XCTAssertEqual(announced, 0)
        withExtendedLifetime(token) {}
    }

    // MARK: S2, falling back to agent 1

    func testDisablingTheActiveAgentMakesAgentOneActiveAndEnablingItAgainDoesNotBringItBack() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        try registry.select(active: bunny.id)
        try registry.update(bunny.id, AgentRecordPatch(enabled: false))
        XCTAssertEqual(registry.activeAgentID, AgentOwner.defaultID)
        try registry.update(bunny.id, AgentRecordPatch(enabled: true))
        XCTAssertEqual(registry.activeAgentID, AgentOwner.defaultID, "the choice was forgotten, not hidden")
    }

    func testDeletingTheActiveAgentMakesAgentOneActive() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        try registry.select(active: bunny.id)
        try registry.delete(bunny.id)
        XCTAssertEqual(registry.activeAgentID, AgentOwner.defaultID)
    }

    func testDisablingAnotherAgentKeepsTheActiveOne() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        let owl = try registry.create(name: "Owl", agentCli: "claude")
        try registry.select(active: bunny.id)
        try registry.update(owl.id, AgentRecordPatch(enabled: false))
        XCTAssertEqual(registry.activeAgentID, bunny.id)
    }

    func testAStoredIdNoAgentHasIsAgentOneAtStartup() async throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        try database.write { try $0.execute("INSERT INTO agent_active(id, agent_id) VALUES(1, 'agent_gone')") }
        XCTAssertEqual(AgentRegistry(database: database).activeAgentID, AgentOwner.defaultID)
    }

    func testTheChoiceChangeIsAnnouncedBeforeADisableMovesIt() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        try registry.select(active: bunny.id)
        var announced = 0
        let token = registry.activeChanges.observe { announced += 1 }
        try registry.update(bunny.id, AgentRecordPatch(enabled: false))
        XCTAssertEqual(announced, 1)
        withExtendedLifetime(token) {}
    }

    // MARK: S4 and S6, who speaks

    private func chats(_ registry: AgentRegistry?) -> AgentChats {
        AgentChats(defaultChat: ChatAPI(session: ChatSession(restore: false)), registry: registry,
                   makeSession: { ChatSession(restore: false, agentID: $0) })
    }

    func testOnlyTheActiveAgentSpeaksAndSelectingAnotherMovesSpeech() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        let hub = chats(registry)
        let supervisor = AgentSupervisor(registry: registry, launcher: hub)
        supervisor.reconcile()
        defer { supervisor.stopAll() }
        try hub.select(active: bunny.id)
        XCTAssertEqual(hub.activeAgentID, bunny.id)
        XCTAssertTrue(hub.speaksReplies(bunny.id))
        XCTAssertFalse(hub.speaksReplies(AgentOwner.defaultID))
        XCTAssertFalse(hub.speaksReplies(nil), "nil is agent 1")
        try hub.select(active: AgentOwner.defaultID)
        XCTAssertTrue(hub.speaksReplies(AgentOwner.defaultID))
        XCTAssertFalse(hub.speaksReplies(bunny.id))
    }

    func testAnActiveAgentWithNoRunningChatLeavesSpeechAndVoiceWithAgentOne() async throws {
        let registry = try memoryRegistry()
        let bunny = try registry.create(name: "Bunny", agentCli: "claude")
        try registry.select(active: bunny.id)
        let hub = chats(registry)
        XCTAssertEqual(hub.activeAgentID, AgentOwner.defaultID, "no process for Bunny yet")
        XCTAssertTrue(hub.speaksReplies(AgentOwner.defaultID))
        XCTAssertFalse(hub.speaksReplies(bunny.id))
    }

    func testWithOnlyAgentOneItIsActiveAndSpeaks() async throws {
        let hub = chats(try memoryRegistry())
        XCTAssertEqual(hub.activeAgentID, AgentOwner.defaultID)
        XCTAssertTrue(hub.speaksReplies(AgentOwner.defaultID))
        XCTAssertThrowsError(try hub.select(active: "agent_nobody"))
        let bare = chats(nil)
        XCTAssertEqual(bare.activeAgentID, AgentOwner.defaultID)
        XCTAssertTrue(bare.speaksReplies(nil))
    }

    // MARK: S5, the highlight

    func testExactlyOnePetIsHighlightedAndOnlyWithSeveralPets() async {
        let both = [AgentOwner.defaultID, "agent_b"]
        XCTAssertEqual(AgentPetSet.highlighted(active: AgentOwner.defaultID, onScreen: both), AgentOwner.defaultID)
        XCTAssertEqual(AgentPetSet.highlighted(active: "agent_b", onScreen: both), "agent_b")
        XCTAssertNil(AgentPetSet.highlighted(active: AgentOwner.defaultID, onScreen: [AgentOwner.defaultID]), "a lone pet looks as it did")
        XCTAssertNil(AgentPetSet.highlighted(active: "agent_c", onScreen: both), "an agent with no pet lights none")
    }
}
