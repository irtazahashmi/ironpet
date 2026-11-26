import XCTest
@testable import IronPet
@testable import IronPetCore

/// S2, the Settings side: the pages read and write agent 1, and what they wrote is there after a restart.
@MainActor
final class AgentSettingsTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("ironpet.db") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-agent-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testSettingsShowAgentOneAndWriteIt() async throws {
        let suite = "ironpet-agent-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("claude", forKey: ChatAgentPreference.key)
        defaults.set("opus", forKey: "chatModel.claude")

        let config = ConfigStore(memory: Config(pet: .init(name: "Boo", sprite: nil)))
        let registry = AgentRegistry(database: try Database(path: file, migrations: AppMigrations.all))
        registry.adoptLegacySettings(defaults: defaults, pet: config.config.pet)
        let chat = ChatSession(restore: false, speech: SpeechPlayer())
        chat.attach(registry: registry)
        let api = APITestSupport.makeAPI(chat: chat, config: config, agents: registry)
        let records = try XCTUnwrap(api.agentRecords)

        let agent = try records.get("agent_default")
        XCTAssertEqual(agent.agentCli, "claude")
        XCTAssertEqual(agent.model, "opus")
        XCTAssertEqual(agent.name, "Boo")

        // The pet's name is changed in Settings, and agent 1 follows.
        try api.settings.patch(PatchSettingsRequest(patch: #"{"pet": {"name": "Pip"}}"#))
        XCTAssertEqual(try records.get("agent_default").name, "Pip")
        api.settings.update { $0.pet.sprite = "/pets/pip.png" }
        XCTAssertEqual(try records.get("agent_default").pet, "/pets/pip.png")

        // The model is changed in the chat settings, and agent 1 holds it after a restart.
        chat.model = "sonnet"
        let restarted = AgentRegistry(database: try Database(path: file, migrations: AppMigrations.all))
        let after = try XCTUnwrap(restarted.chatAgent)
        XCTAssertEqual(after.model, "sonnet")
        XCTAssertEqual(after.name, "Pip")
        XCTAssertEqual(after.pet, "/pets/pip.png")
        XCTAssertEqual(after.agentCli, "claude")
    }

    func testAHostWithoutADatabaseHasNoAgentRecords() async throws {
        let api = APITestSupport.makeAPI()
        XCTAssertNil(api.agentRecords)
    }
}
