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
    /// Taps a button of the long-press menu once it has stopped moving. The menu opens with a spring animation, and on a slow runner a tap
    /// at the position the button had a moment earlier lands outside the menu. That only dismisses it, and the message stays in the outbox.
    private func tapWhenSettled(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the long-press menu has \(button.identifier)")
        var last = button.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = button.frame
            if now == last, button.isHittable { break }
            last = now
        }
        button.tap()
    }

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
        tapWhenSettled(app.buttons["outgoing-delete"])
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: waitingBubble())
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["typed offline"].waitForNonExistence(timeout: 5), "the message is gone from the transcript, and so is the menu preview")
    }
}
