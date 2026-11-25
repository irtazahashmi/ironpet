import IronPetKit
import XCTest

/// A message typed while the Mac is out of reach waits on the phone, and the user can delete it before it goes out.
final class ChatOutboxUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    private func openChat() {
        app.launchArguments = ["--reset-credentials"]
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].waitForExistence(timeout: 20))
    }

    /// The bubble of a message that waits for the connection. Its accessibility value says so, and the clock glyph is hidden from VoiceOver.
    private func waitingBubble() -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Waiting to send'")).firstMatch }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    // S4
    func testAWaitingMessageCanBeDeletedBeforeTheMacIsBack() {
        openChat()
        server.stop()
        let input = app.textViews["chat-input"]
        input.tap()
        input.typeText("typed offline")
        app.buttons["send-button"].tap()
        XCTAssertTrue(waitingBubble().waitForExistence(timeout: 20), "the message shows as waiting to send")
        XCTAssertFalse(app.buttons["outgoing-delete"].exists, "no Delete button row under the message")
        app.staticTexts["typed offline"].press(forDuration: 1)
        app.buttons["outgoing-delete"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: waitingBubble())
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["typed offline"].exists, "the message is gone from the transcript")
    }
}
