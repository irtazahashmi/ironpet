import IronPetKit
import XCTest

/// Mermaid diagrams in the chat: a valid one draws as a diagram, an invalid one shows its source, and a long chat scrolls with
/// several diagrams in it. Screenshots go to the test attachments.
final class ChatMermaidUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!
    var dark = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    static let valid = "Here is the flow:\n\n```mermaid\ngraph TD\n  A[Login] --> B[Refresh token]\n  B --> C{Expired?}\n  C -->|yes| A\n  C -->|no| D[Done]\n```\n\nThat is all."
    static let invalid = "Broken:\n\n```mermaid\nthis is not ((a diagram\n```"

    private func fixture(_ items: [RemoteChatItem]) {
        server.chat.items = items
        server.chat.state = "done"
    }

    private func reply(_ id: String, _ text: String) -> RemoteChatItem { RemoteChatItem(id: id, kind: "assistant", date: Date(), text: text) }

    private func openChat() {
        app.launchArguments = ["--reset-credentials"] + (dark ? ["--force-dark"] : [])
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

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var diagram: XCUIElement { app.descendants(matching: .any)["mermaid-block"].firstMatch }
    private var codeBlock: XCUIElement { app.descendants(matching: .any)["code-block"].firstMatch }

    // S1
    func testAValidDiagramDrawsInLight() { validDiagram() }
    func testAValidDiagramDrawsInDark() { dark = true; validDiagram() }

    private func validDiagram() {
        fixture([reply("m1", Self.valid)])
        openChat()
        XCTAssertTrue(diagram.waitForExistence(timeout: 30), "the diagram shows")
        XCTAssertFalse(codeBlock.exists, "the source is not drawn next to it")
        // It grows to the diagram's height: far taller than the 96 pt it starts with.
        let deadline = Date().addingTimeInterval(20)
        while diagram.frame.height <= 120, Date() < deadline { usleep(200_000) }
        XCTAssertGreaterThan(diagram.frame.height, 120, "the block grows to the drawn diagram")
        XCTAssertLessThanOrEqual(diagram.frame.maxX, app.frame.width, "a diagram that fits the screen does not run past it")
        attach("mermaid-\(dark ? "dark" : "light")")
    }

    // S2
    func testAnInvalidDiagramShowsItsSourceAsCode() {
        fixture([reply("m1", Self.invalid)])
        openChat()
        XCTAssertTrue(codeBlock.waitForExistence(timeout: 30), "the source shows as a code block")
        XCTAssertFalse(diagram.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'could not render'")).firstMatch.exists, "no error text")
        attach("mermaid-invalid")
    }

    // S3
    func testALongChatWithSeveralDiagramsScrolls() {
        var items: [RemoteChatItem] = []
        for n in 1...6 {
            items.append(RemoteChatItem(id: "u\(n)", kind: "user", date: Date(), text: "diagram \(n)"))
            items.append(reply("m\(n)", Self.valid.replacingOccurrences(of: "Done", with: "Done \(n)")))
        }
        fixture(items)
        openChat()
        XCTAssertTrue(diagram.waitForExistence(timeout: 30))
        let transcript = app.descendants(matching: .any)["transcript"].firstMatch
        for _ in 0..<4 { transcript.swipeDown(velocity: .fast) }
        for _ in 0..<4 { transcript.swipeUp(velocity: .fast) }
        XCTAssertTrue(diagram.waitForExistence(timeout: 10), "a diagram is still there after scrolling to the top and back")
        attach("mermaid-scrolled")
    }
}
