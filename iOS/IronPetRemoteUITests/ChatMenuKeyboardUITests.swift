import IronPetKit
import XCTest

/// The long-press menu of a message, with the keyboard up and down. With the keyboard up the transcript used to scroll while the keyboard
/// hid, so the lifted message was drawn at its old place over another message and a bar showed under the tab bar.
final class ChatMenuKeyboardUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openChat() {
        var items: [RemoteChatItem] = []
        for n in 1...8 {
            items.append(RemoteChatItem(id: "u-\(n)", kind: "user", date: Date(), text: "question number \(n) about the build"))
            items.append(RemoteChatItem(id: "a-\(n)", kind: "assistant", date: Date(), text: "Answer number \(n): the build passes once the timeout is ten seconds."))
        }
        server.chat.items = items
        server.chat.state = "done"
        app.launchArguments = ["--reset-credentials"]
        app.launch()
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].waitForExistence(timeout: 20))
    }

    func testTheMenuWithTheKeyboardUpAndDown() {
        openChat()
        let bubble = app.staticTexts["bubble-a-6"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 20))
        attach("menu-1-keyboard-down-before")

        bubble.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5), "the menu opens with the keyboard down")
        attach("menu-2-keyboard-down-menu")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()

        app.textViews["chat-input"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let target = app.staticTexts["bubble-a-7"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        attach("menu-3-keyboard-up-before")
        target.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5), "the menu opens with the keyboard up")
        attach("menu-4-keyboard-up-menu")
    }
}
