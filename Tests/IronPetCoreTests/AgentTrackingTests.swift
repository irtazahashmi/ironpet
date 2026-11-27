import XCTest
@testable import IronPetCore

/// The device-level tracking switch: what it installs, what it removes and what it leaves alone.
final class AgentTrackingTests: XCTestCase {
    private var home: URL!
    private var installer: HookInstaller!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        installer = HookInstaller(locations: .init(
            cursorHooks: home.appendingPathComponent(".cursor/hooks.json"),
            claudeSettings: home.appendingPathComponent(".claude/settings.json"),
            hookScript: home.appendingPathComponent(".ironpet/bin/ironpet-hook"),
            codexHooks: home.appendingPathComponent(".codex/hooks.json"),
            geminiSettings: home.appendingPathComponent(".gemini/settings.json"),
            copilotHooks: home.appendingPathComponent(".copilot/hooks/ironpet.json"),
            piExtension: home.appendingPathComponent(".pi/agent/extensions/ironpet.ts")))
        for agent in HookInstaller.Agent.allCases {
            try FileManager.default.createDirectory(at: installer.file(for: agent).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    /// What the app does on a config change: install for the active agents, remove from every agent when tracking is off.
    private func apply(_ integrations: Config.Integrations) throws {
        try installer.install(integrations.activeAgents)
        if !integrations.trackAgents { try installer.uninstall() }
        else { try installer.uninstall(HookInstaller.Agent.allCases.filter { !integrations.activeAgents.contains($0) }) }
    }

    // S1
    func testTurningTrackingOffRemovesIronpetFromAWatchedAgent() throws {
        var integrations = Config.Integrations(claudeHooks: true)
        try apply(integrations)
        XCTAssertTrue(installer.isInstalled(.claude))
        integrations.setTracking(false, found: [.claude])
        XCTAssertEqual(integrations.activeAgents, [])
        try apply(integrations)
        XCTAssertFalse(installer.isInstalled(.claude))
        XCTAssertTrue(integrations.claudeHooks, "the per-agent choice is kept for when tracking returns")
    }

    // S3
    func testTurningTrackingOnWatchesEveryFoundAgent() throws {
        var integrations = Config.Integrations(trackAgents: false)
        try apply(integrations)
        XCTAssertFalse(installer.isInstalled(.claude))
        integrations.setTracking(true, found: [.claude, .codex])
        XCTAssertEqual(integrations.activeAgents, [.claude, .codex])
        try apply(integrations)
        XCTAssertTrue(installer.isInstalled(.claude))
        XCTAssertTrue(installer.isInstalled(.codex))
        XCTAssertFalse(installer.isInstalled(.gemini), "only agents that were found")
    }

    func testTurningTrackingOnKeepsAnEarlierChoice() {
        var integrations = Config.Integrations(claudeHooks: true, trackAgents: false)
        integrations.setTracking(true, found: [.claude, .codex])
        XCTAssertEqual(integrations.activeAgents, [.claude])
    }

    // S4
    func testRoundTripLeavesTheUsersOwnEntriesUnchanged() throws {
        let claude = installer.locations.claudeSettings
        let codex = installer.locations.codexHooks
        try #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-tool"}]}]}}"#
            .write(to: claude, atomically: true, encoding: .utf8)
        try #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#
            .write(to: codex, atomically: true, encoding: .utf8)
        let before = [try structure(claude), try structure(codex)]
        var integrations = Config.Integrations(trackAgents: false)
        integrations.setTracking(true, found: [.claude, .codex])
        try apply(integrations)
        XCTAssertNotEqual(try structure(claude), before[0])
        integrations.setTracking(false, found: [])
        try apply(integrations)
        XCTAssertEqual(try structure(claude), before[0])
        XCTAssertEqual(try structure(codex), before[1])
    }

    private func structure(_ url: URL) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }

    // Migration
    func testAConfigFileWithoutTheKeyKeepsTrackingOn() throws {
        let file = home.appendingPathComponent("config.json")
        try #"{"integrations":{"claudeHooks":true}}"#.write(to: file, atomically: true, encoding: .utf8)
        let loaded = Config.load(from: file)
        XCTAssertNil(loaded.error)
        XCTAssertTrue(loaded.config.integrations.trackAgents)
        XCTAssertEqual(loaded.config.integrations.activeAgents, [.claude])
    }
}
