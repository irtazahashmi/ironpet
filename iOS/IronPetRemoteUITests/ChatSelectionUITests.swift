import IronPetKit
import XCTest

/// Selecting text in a reply: the selection spans paragraphs and list items, its menu offers "Ask about this", and the rest of the
/// message (Copy, the long-press menu, links) keeps working.
final class ChatSelectionUITests: XCTestCase {
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

    private static let reply = """
    The first paragraph explains the timeout.

    - alpha item
    - beta item

    The last paragraph names `Sources/App/Main.swift` and ends here.
    """

    private func openChat(items: [RemoteChatItem]? = nil) {
        server.chat.items = items ?? [
            RemoteChatItem(id: "m-1", kind: "user", date: Date(), text: "what is the fix?"),
            RemoteChatItem(id: "m-2", kind: "assistant", date: Date(), text: Self.reply),
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

    /// An entry of the edit menu. The system draws it as a menu item or a button, depending on the iOS version.
    private func entry(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)", title, XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
    }

    private var replyBar: XCUIElement { app.descendants(matching: .any)["reply-bar"] }

    /// The reply's element, a static text that holds all its blocks.
    private func replyText() -> XCUIElement {
        let view = app.staticTexts["bubble-m-2"]
        XCTAssertTrue(view.waitForExistence(timeout: 20))
        return view
    }

    /// Long-presses the reply and chooses Select text in the message menu, which selects the run of paragraphs and list items.
    private func selectText() {
        let text = replyText()
        // The first words of the first paragraph, where the press lands on selectable text.
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.04)).press(forDuration: 1.0)
        let select = entry("Select text")
        XCTAssertTrue(select.waitForExistence(timeout: 5), "the message menu has Select text: \(app.debugDescription)")
        select.tap()
    }

    // S1, S2
    func testSelectionSpansParagraphsAndAsksAboutIt() {
        openChat()
        selectText()
        attach("selection-1-all-selected")
        let ask = entry("Ask about this")
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "the menu of the selection offers Ask about this")
        ask.tap()
        XCTAssertTrue(replyBar.waitForExistence(timeout: 5), "the composer replies to the message")
        let quoted = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'first paragraph' AND label CONTAINS 'alpha item'")).count
            + replyBar.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'first paragraph' AND label CONTAINS 'alpha item'")).count
        XCTAssertGreaterThan(quoted, 0, "the quote spans the paragraph and the list: \(replyBar.debugDescription)")
        attach("selection-2-reply-started")
        app.buttons["Cancel reply"].firstMatch.tap()
        XCTAssertFalse(replyBar.exists)
    }

    // S3
    func testTheMessageMenuStillOpensAndCopyWorks() {
        openChat()
        replyText().coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.04)).press(forDuration: 1.0)
        for title in ["Reply", "Copy", "Read Aloud", "Select text"] {
            XCTAssertTrue(entry(title).waitForExistence(timeout: 5), "\(title) is in the message menu")
        }
        attach("selection-3-message-menu")
        entry("Copy").tap()
        selectText()
        XCTAssertTrue(entry("Copy").waitForExistence(timeout: 5), "Copy stays in the selection menu")
        entry("Copy").tap()
    }

    // S5
    func testASelectionStaysWhileAnotherReplyStreams() {
        openChat()
        selectText()
        XCTAssertTrue(entry("Ask about this").waitForExistence(timeout: 5))
        for n in 1...20 {
            server.streamChunk(item: "stream", "w\(n) ")
            Thread.sleep(forTimeInterval: 0.1)
        }
        server.finishTurn()
        attach("selection-5-after-stream")
        let streamed = app.descendants(matching: .any).matching(identifier: "bubble-stream").firstMatch
        XCTAssertTrue(streamed.waitForExistence(timeout: 5))
        XCTAssertTrue(streamed.label.contains("w20"), "the streamed reply kept growing: \(streamed.label)")
    }
}
