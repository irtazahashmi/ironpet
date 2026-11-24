import IronPetKit
import XCTest

/// Find in chat on the phone: a search field that counts the matches, highlights them and steps through them.
final class ChatFindUITests: XCTestCase {
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

    /// "refresh" appears in four messages and five places, with filler between them so the first and the last are not on one screen.
    private func fixture() {
        let now = Date()
        var items = [RemoteChatItem(id: "m-1", kind: "user", date: now, text: "How does the login refresh work?")]
        items.append(RemoteChatItem(id: "m-2", kind: "assistant", date: now, text: "The session stores a token, and **refresh** runs 60 s before it expires.\n\n- retry the refresh twice"))
        for n in 3...14 { items.append(RemoteChatItem(id: "m-\(n)", kind: n % 2 == 0 ? "assistant" : "user", date: now, text: "Filler message number \(n) about something else.")) }
        items.append(RemoteChatItem(id: "m-15", kind: "user", date: now, text: "And a Refresh failure?"))
        for n in 16...27 { items.append(RemoteChatItem(id: "m-\(n)", kind: n % 2 == 0 ? "assistant" : "user", date: now, text: "More filler message number \(n).")) }
        items.append(RemoteChatItem(id: "m-28", kind: "assistant", date: now, text: "It calls `refreshToken()` again."))
        server.chat.items = items
        server.chat.state = "done"
    }

    func testSearchingAWordInSeveralMessagesShowsTheCountAndStepsThroughThem() {
        fixture()
        openChat()
        XCTAssertTrue(app.staticTexts["bubble-m-28"].waitForExistence(timeout: 20) || app.otherElements["bubble-m-28"].waitForExistence(timeout: 5))
        attach("find-1-chat")

        XCTAssertTrue(app.buttons["chat-more-button"].waitForExistence(timeout: 20))
        app.buttons["chat-more-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["chat-find-button"].tap()
        let field = app.textFields["find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("refresh")
        let label = app.staticTexts["find-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        // Five matches, case ignored: m-1, m-2 twice (the bold word and the list item), m-15 and `refreshToken` in m-28.
        expectLabel(label, "1 of 5")
        attach("find-2-first-match")

        app.buttons["find-next"].tap()
        expectLabel(label, "2 of 5")
        app.buttons["find-next"].tap()
        expectLabel(label, "3 of 5")
        attach("find-3-third-match")

        app.buttons["find-previous"].tap()
        expectLabel(label, "2 of 5")
        // Stepping back past the first wraps to the last, which sits at the end of the chat.
        for _ in 0..<2 { app.buttons["find-previous"].tap() }
        expectLabel(label, "5 of 5")
        XCTAssertTrue(app.otherElements["bubble-m-28"].waitForExistence(timeout: 5) || app.staticTexts["bubble-m-28"].exists, "the last match is on screen")
        attach("find-4-wrapped-to-last")

        field.clearAndType("zzzz")
        expectLabel(label, "No results")
        XCTAssertFalse(app.buttons["find-next"].isEnabled)
        attach("find-5-no-results")

        app.buttons["find-done"].tap()
        XCTAssertFalse(app.textFields["find-field"].exists)
    }

    private func expectLabel(_ label: XCUIElement, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: label)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, "label was \(label.label)", file: file, line: line)
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        let current = (value as? String) ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
