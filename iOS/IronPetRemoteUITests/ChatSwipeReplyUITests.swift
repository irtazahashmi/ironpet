import IronPetKit
import XCTest

/// A right swipe on a message starts a reply, the same as Reply in its menu. A short swipe does nothing, a swipe on a code block or a
/// table scrolls it, and the edge swipe still goes back.
final class ChatSwipeReplyUITests: XCTestCase {
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

    private static let blocks = """
    The fix is one line.

    ```swift
    let reallyLongLineThatOverflowsTheBubbleAndNeedsToScrollSideways = computeSomething(withManyArguments: first, second, third, fourth)
    ```

    | Name | Value | Notes |
    |---|---|---|
    | alpha | 1 | a very long note that makes this table wider than the screen so that it scrolls sideways |
    """

    private func openChat() {
        server.chat.items = [
            RemoteChatItem(id: "m-1", kind: "user", date: Date(), text: "what is the fix?"),
            RemoteChatItem(id: "m-2", kind: "assistant", date: Date(), text: "Change the timeout to ten seconds."),
            RemoteChatItem(id: "m-3", kind: "assistant", date: Date(), text: Self.blocks),
        ]
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

    private var replyBar: XCUIElement { app.descendants(matching: .any)["reply-bar"] }

    /// Drags from `dx` points right of the element's left edge to `distance` points further right (or left, when negative).
    private func drag(_ element: XCUIElement, from dx: CGFloat, by distance: CGFloat, hold: TimeInterval = 0, at row: CGFloat = 0.5) {
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: (frame.minX + dx) / window.width, dy: (frame.minY + frame.height * row) / window.height))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: (frame.minX + dx + distance) / window.width, dy: (frame.minY + frame.height * row) / window.height))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: hold > 0 ? .slow : .fast, thenHoldForDuration: hold)
    }

    func testARightSwipeStartsAReplyAndAShortOneDoesNot() {
        openChat()
        let bubble = app.staticTexts["bubble-m-2"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 20))
        attach("swipe-1-before")

        let restX = bubble.frame.minX
        drag(bubble, from: 40, by: 30)
        XCTAssertFalse(replyBar.waitForExistence(timeout: 1.5), "a short swipe does nothing")
        XCTAssertEqual(bubble.frame.minX, restX, accuracy: 1, "the message springs back to its place")

        drag(bubble, from: 40, by: 220)
        XCTAssertTrue(replyBar.waitForExistence(timeout: 5), "a long swipe starts a reply")
        XCTAssertTrue(app.staticTexts["Change the timeout to ten seconds."].exists)
        attach("swipe-3-reply-started")
        app.buttons["Cancel reply"].firstMatch.tap()
        XCTAssertFalse(replyBar.exists)
    }

    /// Drags across the screen at the height of `element`, from `fromX` to `toX` points. The element's own frame can be wider than the screen.
    private func sweep(at element: XCUIElement, from fromX: CGFloat, to toX: CGFloat) {
        let window = app.windows.firstMatch
        let y = element.frame.midY / window.frame.height
        window.coordinate(withNormalizedOffset: CGVector(dx: fromX / window.frame.width, dy: y))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: toX / window.frame.width, dy: y)), withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// The two sideways scroll views of the reply that holds a code block and a table, code first.
    private func blocks() -> (code: XCUIElement, table: XCUIElement) {
        XCTAssertTrue(app.staticTexts["bubble-m-3"].exists || app.buttons["bubble-m-3"].waitForExistence(timeout: 20))
        let found = app.scrollViews.allElementsBoundByIndex.filter { $0.frame.height < 90 && $0.frame.width > 250 && $0.frame.width < 330 }
        XCTAssertEqual(found.count, 2, "a code block and a table: \(app.debugDescription)")
        return (found[0], found[1])
    }

    /// Where the scroll view's content starts. It moves left as the view scrolls right.
    private func contentX(_ scroll: XCUIElement) -> CGFloat { scroll.children(matching: .other).firstMatch.frame.minX }

    func testASwipeOnACodeBlockOrATableScrollsItAndDoesNotReply() {
        openChat()
        let (code, table) = blocks()
        for (name, block) in [("code", code), ("table", table)] {
            let start = contentX(block)
            sweep(at: block, from: 330, to: 120)
            XCTAssertLessThan(contentX(block), start - 40, "a left swipe on the \(name) scrolls it")
            if name == "code" { attach("swipe-4-code-scrolled") }
            XCTAssertFalse(replyBar.exists, "a left swipe on the \(name) is not a reply")
            sweep(at: block, from: 80, to: 330)
            XCTAssertFalse(replyBar.waitForExistence(timeout: 1.5), "a right swipe on the \(name) is not a reply")
            XCTAssertGreaterThan(contentX(block), start - 20, "the \(name) is back at its start")
        }
        attach("swipe-5-blocks")
    }

    func testTheEdgeSwipeStillGoesBack() {
        openChat()
        let bubble = app.staticTexts["bubble-m-2"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 20))
        // From the screen edge on a message of the open chat, nothing is a reply.
        let window = app.windows.firstMatch
        let edgeStart = window.coordinate(withNormalizedOffset: CGVector(dx: 2 / window.frame.width, dy: bubble.frame.midY / window.frame.height))
        edgeStart.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: bubble.frame.midY / window.frame.height)))
        XCTAssertFalse(replyBar.waitForExistence(timeout: 1.5), "an edge swipe is the back swipe, not a reply")

        // And on a pushed screen the edge swipe goes back.
        app.buttons["threads-button"].tap()
        let thread = app.buttons["thread-th-1"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.tap()
        XCTAssertTrue(app.staticTexts["Old answer"].waitForExistence(timeout: 10))
        let sheet = app.windows.firstMatch
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 2 / sheet.frame.width, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(app.buttons["thread-th-1"].waitForExistence(timeout: 10), "the edge swipe went back to the list")
        attach("swipe-6-back")
    }
}
