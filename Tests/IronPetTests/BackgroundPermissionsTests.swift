import XCTest
@testable import IronPet
@testable import IronPetCore

/// What the phone, Telegram and the alerts list see of a permission request from a job or an automation session.
@MainActor
final class BackgroundPermissionsTests: XCTestCase {
    private let options = [PermissionOption(id: "a", name: "Allow", kind: "allow_once"),
                           PermissionOption(id: "x", name: "Something new", kind: "ask_later"),
                           PermissionOption(id: "r", name: "Reject", kind: "reject_once")]

    private func call() -> ACPToolCall {
        var call = ACPToolCall(id: "1", title: "Bash", kind: "execute", rawInput: ["command": "make"], toolName: "Bash")
        call.permissionOptions = options
        return call
    }

    func testTheChatAPIListsAndAnswersABackgroundRequestWithTheAgentsOptions() async throws {
        let permissions = BackgroundPermissions(signals: SignalStore())
        let api = ChatAPI(session: ChatSession(restore: false))
        api.background = permissions
        var decision: ApprovalDecision?
        let id = permissions.ask(owner: "job-1", source: "Job \"Build\"", call: call(), respond: { decision = $0 }, timedOut: { _ in })
        let listed = await api.approvals()
        XCTAssertEqual(listed.map(\.id), [id])
        XCTAssertTrue(listed[0].title.contains("Job \"Build\""))
        XCTAssertEqual(listed[0].options?.map(\.name), ["Allow", "Something new", "Reject"], "an unknown kind still has its button")
        let status = await api.status()
        XCTAssertEqual(status.pendingApprovals, 0, "a background request does not hold the chat")
        do {
            try await api.decide(DecideApprovalRequest(id: id, allow: true, option: "nope"))
            XCTFail("an option the agent did not offer is refused")
        } catch {}
        try await api.decide(DecideApprovalRequest(id: id, allow: false, option: "x"))
        XCTAssertEqual(decision?.optionID, "x", "an option ironpet has no name for goes back as the agent's id")
        XCTAssertTrue(permissions.pending.isEmpty)
    }

    func testDenyFromAClientWithoutOptionsPicksRejectOnce() async throws {
        let permissions = BackgroundPermissions()
        let api = ChatAPI(session: ChatSession(restore: false))
        api.background = permissions
        var decision: ApprovalDecision?
        let id = permissions.ask(owner: "job-1", source: "Job", call: call(), respond: { decision = $0 }, timedOut: { _ in })
        try await api.decide(DecideApprovalRequest(id: id, allow: false))
        XCTAssertEqual(decision?.optionID, "r")
    }

    func testDismissingTheAlertRefusesTheRequest() throws {
        let signals = SignalStore()
        let permissions = BackgroundPermissions(signals: signals)
        let alerts = AlertsAPI(store: signals)
        alerts.permissions = permissions
        var decision: ApprovalDecision?
        let id = permissions.ask(owner: "job-1", source: "Job", call: call(), respond: { decision = $0 }, timedOut: { _ in })
        try alerts.dismiss(BackgroundPermissions.alertID(id))
        XCTAssertEqual(decision?.optionID, "r")
        XCTAssertTrue(signals.signals.isEmpty)
    }

    func testARunThatEndsTakesItsRequestsDown() {
        let signals = SignalStore()
        let permissions = BackgroundPermissions(signals: signals)
        var resolved: [BackgroundPermissions.Outcome] = []
        permissions.observe(raised: { _ in }, resolved: { _, outcome in resolved.append(outcome) })
        var decision: ApprovalDecision?
        permissions.ask(owner: "job-1", source: "Job", call: call(), respond: { decision = $0 }, timedOut: { _ in })
        permissions.end(owner: "job-1")
        XCTAssertEqual(decision?.allow, false)
        XCTAssertEqual(resolved, [.ended])
        XCTAssertTrue(signals.signals.isEmpty)
    }

    func testTheBubbleHasOneButtonPerAgentOption() {
        let request = BackgroundPermissions.Request(id: UUID(), owner: "o", source: "Job", tool: "Bash", title: "Run this command?",
                                                    detail: "make", options: options, date: Date())
        var chosen: String?
        let bubble = Announcer.backgroundPermissionBubble(request, answer: { chosen = $0 }, openChat: {})
        XCTAssertEqual(bubble.actions.map(\.title), ["Allow", "Something new", "Reject"])
        bubble.handlers.actions["option:x"]?()
        XCTAssertEqual(chosen, "x")
    }
}
