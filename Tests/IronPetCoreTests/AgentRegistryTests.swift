import XCTest
@testable import IronPetCore

/// The `agents` table: agent 1 is today's chat agent, it keeps the settings the user had, Settings write it, and a database made by
/// an older build upgrades without losing a row.
@MainActor
final class AgentRegistryTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("ironpet.db") }
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "ironpet-agents-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: S4, a fresh database

    func testAFreshDatabaseHasAgentOneWithTheDefaults() async throws {
        let registry = AgentRegistry(database: try Database(path: nil, migrations: AppMigrations.all))
        let all = registry.list()
        XCTAssertEqual(all.count, 1)
        let agent = try XCTUnwrap(all.first)
        XCTAssertEqual(agent.id, AgentID.default.rawValue, "agent 1 keeps the id every write was attributed to")
        XCTAssertEqual(agent.number, 1)
        XCTAssertEqual(agent.name, "Ghost")
        XCTAssertEqual(agent.agentCli, ChatAgentPreference.defaultID)
        XCTAssertNil(agent.model)
        XCTAssertNil(agent.pet)
        XCTAssertEqual(agent.instructions, "")
        XCTAssertEqual(agent.permissions, [:])
    }

    func testWritesAfterTheUpgradeAreAttributedToAgentOne() async throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        let registry = AgentRegistry(database: database)
        let store = TaskStore(database: database, keepDoneDays: { 30 })
        _ = try store.create(title: "A task", source: .user, by: "user")
        let agents = try database.read { try $0.rows("SELECT DISTINCT agent_id FROM task_events").map { $0[0] as? String } }
        XCTAssertEqual(agents, [registry.chatAgent?.id])
        XCTAssertEqual(registry.get(try XCTUnwrap(agents.first ?? nil))?.number, 1)
    }

    func testAnEmptyOrDefaultAgentIdResolvesToAgentOne() async throws {
        let registry = AgentRegistry(database: try Database(path: nil, migrations: AppMigrations.all))
        XCTAssertEqual(registry.get("")?.number, 1, "a row with no agent id still resolves")
        XCTAssertEqual(registry.get("agent_default")?.number, 1)
        XCTAssertNil(registry.get("agent_other"))
    }

    // MARK: S2, settings from before the upgrade

    func testAgentOneHoldsTheSettingsSavedBeforeTheUpgrade() async throws {
        defaults.set("claude", forKey: ChatAgentPreference.key)
        defaults.set("opus", forKey: "chatModel.claude")
        defaults.set("gpt-x", forKey: "chatModel.cursor")
        let registry = AgentRegistry(database: try Database(path: file, migrations: AppMigrations.all))
        registry.adoptLegacySettings(defaults: defaults, pet: Config.Pet(name: "Boo", sprite: "/pets/boo.png"))
        let agent = try XCTUnwrap(registry.chatAgent)
        XCTAssertEqual(agent.agentCli, "claude")
        XCTAssertEqual(agent.model, "opus")
        XCTAssertEqual(agent.cliModels, ["claude": "opus", "cursor": "gpt-x"])
        XCTAssertEqual(agent.name, "Boo")
        XCTAssertEqual(agent.pet, "/pets/boo.png")
    }

    func testTheLegacyCopyRunsOnceAndNeverOverwritesWhatSettingsWroteSince() async throws {
        defaults.set("claude", forKey: ChatAgentPreference.key)
        let database = try Database(path: file, migrations: AppMigrations.all)
        let registry = AgentRegistry(database: database)
        registry.adoptLegacySettings(defaults: defaults, pet: Config.Pet())
        try registry.update(AgentID.default.rawValue, AgentRecordPatch(agentCli: "cursor", instructions: "Be brief"))
        defaults.set("claude", forKey: ChatAgentPreference.key)
        registry.adoptLegacySettings(defaults: defaults, pet: Config.Pet(name: "Other"))
        let agent = try XCTUnwrap(registry.chatAgent)
        XCTAssertEqual(agent.agentCli, "cursor")
        XCTAssertEqual(agent.instructions, "Be brief")
        XCTAssertEqual(agent.name, "Ghost")
    }

    func testTheChatReadsAndWritesAgentOneAndItSurvivesARestart() async throws {
        defaults.set("claude", forKey: ChatAgentPreference.key)
        defaults.set("opus", forKey: "chatModel.claude")
        let registry = AgentRegistry(database: try Database(path: file, migrations: AppMigrations.all))
        registry.adoptLegacySettings(defaults: defaults, pet: Config.Pet())

        let chat = ChatSession(restore: false)
        chat.attach(registry: registry)
        XCTAssertEqual(chat.agent.id, "claude", "the chat starts on agent 1's CLI")
        XCTAssertEqual(chat.model, "opus")

        chat.model = "sonnet"
        XCTAssertEqual(registry.chatAgent?.model, "sonnet", "a model pick writes agent 1")
        let other = try XCTUnwrap(AgentCatalog.all.first { $0.id != "claude" })
        chat.setAgent(other)
        XCTAssertEqual(registry.chatAgent?.agentCli, other.id, "a CLI pick writes agent 1")
        chat.setAgent(try XCTUnwrap(AgentCatalog.agent(id: "claude")))
        XCTAssertEqual(chat.model, "sonnet", "switching back brings back the model picked for that CLI")

        let reopened = AgentRegistry(database: try Database(path: file, migrations: AppMigrations.all))
        XCTAssertEqual(reopened.chatAgent?.agentCli, "claude")
        XCTAssertEqual(reopened.chatAgent?.model, "sonnet")
        let restarted = ChatSession(restore: false)
        restarted.attach(registry: reopened)
        XCTAssertEqual(restarted.agent.id, "claude")
        XCTAssertEqual(restarted.model, "sonnet")
    }

    func testChangingThePetMirrorsOntoAgentOne() async throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        let api = AgentRecordsAPI(registry: AgentRegistry(database: database))
        api.mirror(pet: Config.Pet(name: "Boo", sprite: "/p.png"))
        XCTAssertEqual(api.chatAgent?.name, "Boo")
        XCTAssertEqual(api.chatAgent?.pet, "/p.png")
        api.mirror(pet: Config.Pet(name: "Boo", sprite: nil))
        XCTAssertNil(api.chatAgent?.pet, "clearing the sprite clears it on the agent")
    }

    func testAnUnknownAgentIsNotFound() async throws {
        let api = AgentRecordsAPI(registry: AgentRegistry(database: try Database(path: nil, migrations: AppMigrations.all)))
        XCTAssertThrowsError(try api.get("agent_nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertThrowsError(try api.update("agent_nope", AgentRecordPatch(name: "x"))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    // MARK: MCP

    func testTheMCPToolsListAndGetAgentOne() async throws {
        let api = AgentRecordsAPI(registry: AgentRegistry(database: try Database(path: nil, migrations: AppMigrations.all)))
        XCTAssertEqual(AgentMCP.tools.compactMap { $0["name"] as? String }, ["agents_list", "agents_get", "agents_create", "agents_update", "agents_delete"])
        XCTAssertTrue(MCPEndpoint.tools.contains { $0["name"] as? String == "agents_get" })
        let list = try XCTUnwrap(try AgentMCP.call("agents_list", [:], api: api).get() as? [String: Any])
        let agents = try XCTUnwrap(list["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?["id"] as? String, "agent_default")
        XCTAssertEqual(agents.first?["agentCli"] as? String, "cursor")
        let one = try XCTUnwrap(try AgentMCP.call("agents_get", ["id": "agent_default"], api: api).get() as? [String: Any])
        XCTAssertEqual(one["number"] as? Int, 1)
        for arguments in [[:], ["id": "agent_nope"]] as [[String: Any]] {
            if case .success = AgentMCP.call("agents_get", arguments, api: api) { XCTFail("agents_get \(arguments) should fail") }
        }
    }

    // MARK: Idempotent migration

    func testRerunningTheMigrationsChangesNothing() async throws {
        let first = try Database(path: file, migrations: AppMigrations.all)
        let registry = AgentRegistry(database: first)
        try registry.update(AgentID.default.rawValue, AgentRecordPatch(instructions: "Keep me"))
        let before = registry.list()
        let second = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(AgentRegistry(database: second).list(), before)
        XCTAssertEqual(second.schemaVersion, AppMigrations.latestVersion)
    }
}
