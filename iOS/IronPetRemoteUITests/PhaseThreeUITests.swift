import IronPetKit
import XCTest

/// Phase 3 against the mock server: the five tabs, a streamed reply and an approval.
final class PhaseThreeUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
        app.launchArguments = ["--reset-credentials"]
    }

    override func tearDown() { server.stop() }

    private func pair() {
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
    }

    private func openChat() {
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    // S18
    func testTheTabBarHasFiveTabsAndDeviceSitsBehindTheGear() {
        pair()
        XCTAssertTrue(app.tabBars.buttons["Pet"].waitForExistence(timeout: 20))
        let names = app.tabBars.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(names, ["Pet", "Chat", "Inbox", "Agents", "More"])
        XCTAssertFalse(app.tabBars.buttons["Device"].exists)
        app.buttons["device-button"].tap()
        XCTAssertTrue(app.buttons["unpair-button"].waitForExistence(timeout: 10), "the Device screen opens from the gear")
        attach("device")
    }

    // S14
    func testAStreamedReplyEndsWithTheFullTextAtTheBottom() {
        server.chat.items = (1...30).map { RemoteChatItem(id: "old-\($0)", kind: $0 % 2 == 0 ? "assistant" : "user", text: "Earlier message number \($0)") }
        pair()
        openChat()
        XCTAssertTrue(any("bubble-old-30").waitForExistence(timeout: 20), "the chat opens at its newest message")
        var expected = ""
        for index in 1...50 {
            expected += "w\(index) "
            server.streamChunk(item: "m-stream", "w\(index) ")
        }
        server.finishTurn()
        let bubble = any("bubble-m-stream")
        XCTAssertTrue(bubble.waitForExistence(timeout: 20))
        let full = NSPredicate { _, _ in bubble.label.trimmingCharacters(in: .whitespaces) == expected.trimmingCharacters(in: .whitespaces) }
        wait(for: [XCTNSPredicateExpectation(predicate: full, object: nil)], timeout: 20)
        XCTAssertEqual(bubble.label.trimmingCharacters(in: .whitespaces), expected.trimmingCharacters(in: .whitespaces))
        XCTAssertTrue(bubble.isHittable, "the transcript stays scrolled to the newest text")
        attach("stream")
    }

    // S15
    func testAllowSendsTheDecisionAndTheCardGoesWhenTheMacSaysSo() {
        server.chat.approvals = [RemoteApproval(id: "ap-1", title: "Run this command?", detail: "npm test")]
        pair()
        openChat()
        let allow = app.buttons["allow-ap-1"]
        XCTAssertTrue(allow.waitForExistence(timeout: 20))
        attach("approval")
        allow.tap()
        let decided = NSPredicate { _, _ in self.server.requests.contains { $0.path == "/v1/chat/approvals/ap-1" && $0.json["allow"] as? Bool == true } }
        wait(for: [XCTNSPredicateExpectation(predicate: decided, object: nil)], timeout: 10)
        XCTAssertTrue(any("approval-ap-1").waitForNonExistence(timeout: 10), "the card goes after chat.state approvals")
    }

    func testSendingAMessageShowsItInTheTranscript() {
        pair()
        openChat()
        let input = app.textViews["chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        input.typeText("hello")
        app.buttons["send-button"].tap()
        let sent = NSPredicate { _, _ in self.server.requests.contains { $0.path == "/v1/chat/current/messages" && $0.json["text"] as? String == "hello" } }
        wait(for: [XCTNSPredicateExpectation(predicate: sent, object: nil)], timeout: 10)
        XCTAssertTrue(app.staticTexts["hello"].waitForExistence(timeout: 10))
    }

    func testOpenOnMacShowsTheConflictAsAnAlert() {
        server.openConflict = "The agent is working. Stop it first, or wait for it to finish."
        pair()
        openChat()
        XCTAssertTrue(app.buttons["chat-more-button"].waitForExistence(timeout: 20))
        app.buttons["chat-more-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["threads-button"].tap()
        let thread = app.buttons["thread-th-1"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.tap()
        app.buttons["open-on-mac-button"].tap()
        XCTAssertTrue(app.alerts.staticTexts["The agent is working. Stop it first, or wait for it to finish."].waitForExistence(timeout: 10))
        attach("conflict")
    }
}
