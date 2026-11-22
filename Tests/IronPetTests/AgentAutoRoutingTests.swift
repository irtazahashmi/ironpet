import XCTest
@testable import IronPet
@testable import IronPetCore

/// Which approval path a permission request takes in a chat: the agent's mode decides what it sends, and what it sends gets a card.
@MainActor
final class AgentModeRoutingTests: XCTestCase {
    private func shell(_ command: String) -> ACPToolCall {
        ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": command])
    }

    private func decide(_ chat: ChatSession, _ call: ACPToolCall) -> ApprovalDecision? {
        var decision: ApprovalDecision?
        chat.handlePermission(call) { decision = $0 }
        return decision
    }

    // S4 and S7: nothing is answered on ironpet's own, whatever the kind or the mode.
    func testEveryRequestGetsACardWithNoPatternCheck() {
        let chat = ChatSession(restore: false)
        chat.receiveModes(current: "auto", modes: [AgentMode(id: "auto", name: "Auto")])
        for call in [shell("rm -rf .build"), shell("ls"), ACPToolCall(id: "r", title: "Read", kind: "read", rawInput: ["path": "a"]),
                     ACPToolCall(id: "m", title: "mcp__sentry__search_issues", kind: "other"),
                     ACPToolCall(id: "n", title: "Edit note", kind: "edit", rawInput: ["file_path": FileMemoryStore.directory.appendingPathComponent("a.md").path])] {
            XCTAssertNil(decide(chat, call), call.title)
        }
        XCTAssertEqual(chat.approvals.count, 5)
        XCTAssertEqual(chat.approvals.first?.title, "Run this command?")
    }

    func testIdenticalRequestsGetOneCardEachBecauseTheirOptionIdsDiffer() {
        let chat = ChatSession(restore: false)
        _ = decide(chat, shell("ls"))
        _ = decide(chat, shell("ls"))
        XCTAssertEqual(chat.approvals.count, 2)
    }

    func testTheCardCarriesExactlyTheAgentsOptionsAndTheChoiceGoesBackAsItsId() {
        let chat = ChatSession(restore: false)
        var call = ACPToolCall(id: "p", title: "Ready to code?", kind: "switch_mode", rawInput: ["plan": "do it"])
        call.permissionOptions = [PermissionOption(id: "acceptEdits", name: "Yes, and auto-accept edits", kind: "allow_always"),
                                  PermissionOption(id: "plan", name: "No, keep planning", kind: "reject_once"),
                                  PermissionOption(id: "x", name: "Odd one", kind: "mystery")]
        var decision: ApprovalDecision?
        chat.handlePermission(call) { decision = $0 }
        let card = chat.approvals[0]
        XCTAssertEqual(card.title, "Ready to code?")
        XCTAssertEqual(card.detail, "do it")
        XCTAssertEqual(card.options.map(\.name), ["Yes, and auto-accept edits", "No, keep planning", "Odd one"])
        chat.decide(id: card.id, optionID: "nope")
        XCTAssertNil(decision, "an option the agent did not offer answers nothing")
        chat.decide(id: card.id, optionID: "x")
        XCTAssertEqual(decision?.optionID, "x")
        XCTAssertTrue(chat.approvals.isEmpty)
    }

    func testAllowAndDenyFromAClientWithoutOptionButtonsPickTheOnceOptions() {
        let chat = ChatSession(restore: false)
        var call = shell("ls")
        call.permissionOptions = [PermissionOption(id: "a", name: "Always", kind: "allow_always"), PermissionOption(id: "o", name: "Once", kind: "allow_once"),
                                  PermissionOption(id: "r", name: "No", kind: "reject_once")]
        var decisions: [ApprovalDecision] = []
        chat.handlePermission(call) { decisions.append($0) }
        chat.handlePermission(call) { decisions.append($0) }
        chat.decide(id: chat.approvals[0].id, allow: true)
        chat.decide(id: chat.approvals[0].id, allow: false)
        XCTAssertEqual(decisions.map(\.optionID), ["o", "r"])
    }

    // S3
    func testPickingAModeStoresItPerAgentAndShowsItAtOnce() {
        let key = "chatMode.test-agent"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let chat = ChatSession(restore: false)
        chat.receiveModes(current: "default", modes: [AgentMode(id: "default", name: "Default"), AgentMode(id: "plan", name: "Plan")])
        chat.setMode("nonsense")
        XCTAssertEqual(chat.agentMode, "default", "a mode the agent did not advertise is refused")
        chat.setMode("plan")
        XCTAssertEqual(chat.agentMode, "plan")
    }
}
