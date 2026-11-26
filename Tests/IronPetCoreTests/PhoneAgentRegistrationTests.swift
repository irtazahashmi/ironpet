import XCTest
@testable import IronPetCore

/// The agent a paired phone registers with the Mac.
@MainActor
final class PhoneAgentRegistrationTests: XCTestCase {
    private func registry() throws -> AgentRegistry {
        AgentRegistry(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    // MARK: S5

    func testAPhoneAgentIsListedAsAnAgentOfTheNodeWithItsDeviceAndProvider() throws {
        let registry = try registry()
        let record = try registry.registerDevice("dev_1", name: "Ghost on iPhone", provider: "anthropic", model: "claude-sonnet-5-5")
        XCTAssertEqual(registry.list().map(\.id), [AgentRegistry.chatAgentID, record.id])
        XCTAssertEqual(record.number, 2)
        XCTAssertEqual(record.deviceID, "dev_1")
        XCTAssertEqual(registry.get(record.id)?.agentCli, "anthropic")
        XCTAssertEqual(registry.get(record.id)?.model, "claude-sonnet-5-5")
        XCTAssertTrue(record.isRemote)
        XCTAssertTrue(record.enabled)
    }

    func testRegisteringAgainUpdatesTheRecordOfThatDeviceInsteadOfAddingOne() throws {
        let registry = try registry()
        let first = try registry.registerDevice("dev_1", name: "Ghost on iPhone", provider: "anthropic", model: nil)
        let second = try registry.registerDevice("dev_1", name: "Ghost on iPhone", provider: "openai", model: "gpt-5")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(registry.list().count, 2)
        XCTAssertEqual(registry.get(first.id)?.agentCli, "openai")
        let other = try registry.registerDevice("dev_2", name: "Ghost on iPad", provider: "anthropic", model: nil)
        XCTAssertNotEqual(other.id, first.id)
    }

    func testAPhoneAgentStartsNoProcessShowsNoPetAndOffersNoChatOnTheMac() throws {
        let registry = try registry()
        try registry.registerDevice("dev_1", name: "Ghost on iPhone", provider: "anthropic", model: nil)
        XCTAssertEqual(registry.enabledAgents().map(\.id), [AgentRegistry.chatAgentID])
        XCTAssertEqual(AgentPetSet.slots(for: registry.list()).map(\.agentID), [AgentRegistry.chatAgentID])
        XCTAssertFalse(AgentSwitcher(records: registry.list(), current: AgentRegistry.chatAgentID).isVisible)
        let launcher = FakeLauncher()
        let supervisor = AgentSupervisor(registry: registry, launcher: launcher)
        supervisor.reconcile()
        XCTAssertEqual(launcher.launched.map(\.launch.agentID), [AgentRegistry.chatAgentID], "only agent 1 got a process")
        supervisor.stopAll()
    }

    func testAPhoneAgentCannotBeMadeTheActiveAgent() throws {
        let registry = try registry()
        let record = try registry.registerDevice("dev_1", name: "Ghost on iPhone", provider: "anthropic", model: nil)
        XCTAssertThrowsError(try registry.select(active: record.id))
        XCTAssertEqual(registry.activeAgentID, AgentRegistry.chatAgentID)
    }

    func testUnpairingADeviceRemovesItsAgentAndLeavesTheOthers() throws {
        let registry = try registry()
        try registry.registerDevice("dev_1", name: "Ghost on iPhone", provider: "anthropic", model: nil)
        let kept = try registry.registerDevice("dev_2", name: "Ghost on iPad", provider: "anthropic", model: nil)
        registry.prune(devices: ["dev_2"])
        XCTAssertEqual(registry.list().map(\.id), [AgentRegistry.chatAgentID, kept.id])
        registry.prune(devices: [])
        XCTAssertEqual(registry.list().map(\.id), [AgentRegistry.chatAgentID], "agent 1 never belongs to a device")
    }

    func testARecordThatHasNoDeviceDecodesAsAMacAgent() throws {
        let json = #"{"id":"agent_x","number":2,"name":"X","agentCli":"claude","cliModels":{},"instructions":"","permissions":{}}"#
        XCTAssertNil(try JSONDecoder().decode(AgentRecord.self, from: Data(json.utf8)).deviceID)
    }
}
