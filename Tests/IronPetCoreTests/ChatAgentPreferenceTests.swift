import XCTest
@testable import IronPetCore

final class ChatAgentPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ironpet-chat-agent-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testMigratesClaudeFromLegacyKey() {
        defaults.set("claude", forKey: ChatAgentPreference.legacyKey)
        XCTAssertEqual(ChatAgentPreference.resolveID(defaults: defaults), "claude")
        XCTAssertEqual(defaults.string(forKey: ChatAgentPreference.key), "claude")
        XCTAssertEqual(defaults.string(forKey: ChatAgentPreference.legacyKey), "claude", "legacy key stays for idempotency")
    }

    func testMigratesCursorFromLegacyKey() {
        defaults.set("cursor", forKey: ChatAgentPreference.legacyKey)
        XCTAssertEqual(ChatAgentPreference.resolveID(defaults: defaults), "cursor")
        XCTAssertEqual(defaults.string(forKey: ChatAgentPreference.key), "cursor")
    }

    func testPrefersExistingChatAgent() {
        defaults.set("claude", forKey: ChatAgentPreference.key)
        defaults.set("cursor", forKey: ChatAgentPreference.legacyKey)
        XCTAssertEqual(ChatAgentPreference.resolveID(defaults: defaults), "claude")
        XCTAssertEqual(defaults.string(forKey: ChatAgentPreference.legacyKey), "cursor", "does not rewrite when new key is set")
    }

    func testIgnoresUnknownLegacyValue() {
        defaults.set("not-an-agent", forKey: ChatAgentPreference.legacyKey)
        XCTAssertEqual(ChatAgentPreference.resolveID(defaults: defaults), ChatAgentPreference.defaultID)
        XCTAssertNil(defaults.string(forKey: ChatAgentPreference.key))
    }

    func testDefaultsToCursorWhenBothMissing() {
        XCTAssertEqual(ChatAgentPreference.resolveID(defaults: defaults), "cursor")
        XCTAssertNil(defaults.string(forKey: ChatAgentPreference.key))
    }

    func testSecondResolveIsIdempotent() {
        defaults.set("claude", forKey: ChatAgentPreference.legacyKey)
        XCTAssertEqual(ChatAgentPreference.resolveID(defaults: defaults), "claude")
        XCTAssertEqual(ChatAgentPreference.resolveID(defaults: defaults), "claude")
        XCTAssertEqual(defaults.string(forKey: ChatAgentPreference.key), "claude")
    }

    func testIgnoresUnknownChatAgentAndFallsBackToLegacy() {
        defaults.set("gone", forKey: ChatAgentPreference.key)
        defaults.set("claude", forKey: ChatAgentPreference.legacyKey)
        XCTAssertEqual(ChatAgentPreference.resolveID(defaults: defaults), "claude")
        XCTAssertEqual(defaults.string(forKey: ChatAgentPreference.key), "claude")
    }

    @MainActor
    func testAutomationPromptUsesMigratedChatAgent() {
        defaults.set("claude", forKey: ChatAgentPreference.legacyKey)
        let automation = Automation(id: "a", name: "a", trigger: .init(type: "interval", minutes: 45),
                                    action: .init(type: "prompt", prompt: "hi"))
        XCTAssertEqual(AutomationPrompt.agentID(automation, defaults: defaults), "claude")
        XCTAssertEqual(defaults.string(forKey: ChatAgentPreference.key), "claude")
    }

    @MainActor
    func testAutomationPromptKeepsItsOwnAgent() {
        defaults.set("claude", forKey: ChatAgentPreference.legacyKey)
        let automation = Automation(id: "a", name: "a", trigger: .init(type: "interval", minutes: 45),
                                    action: .init(type: "prompt", prompt: "hi", agent: "cursor"))
        XCTAssertEqual(AutomationPrompt.agentID(automation, defaults: defaults), "cursor")
        XCTAssertNil(defaults.string(forKey: ChatAgentPreference.key), "own agent does not trigger a migrate")
    }
}
