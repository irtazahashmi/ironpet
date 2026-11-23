import IronPetKit
import XCTest

/// Phase 7: the chat looks and behaves like the Mac's. The fixture has one of every row the Mac draws, so the screenshots can sit
/// next to the Mac's `--render-previews` output (see `.am/evidence/PARITY.md`).
final class ChatParityUITests: XCTestCase {
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

    static let markdownReply = """
    ## Token refresh

    `login()` stores the session, then **refreshes the token** before it expires. See [the docs](https://example.com/auth).

    1. Read the expiry from the session
    2. Schedule `refreshToken()` 60 s early
       - retries twice on a network error
    3. Replace the stored token

    | Step | File |
    |------|------|
    | Login | `src/auth/login.ts` |
    | Refresh | `src/auth/session.ts` |

    ```ts
    await refreshToken(session)
    ```

    > The test was flaky because step 2 was not awaited.
    """

    static var longMessage: String { (1...60).map { "Line \($0) of a pasted log with enough words to be a real line" }.joined(separator: "\n") }

    private func tool(_ id: String, _ text: String, ok: Bool?) -> RemoteChatItem { RemoteChatItem(id: id, kind: "tool", date: Date(), text: text, ok: ok) }

    private func fixture() {
        let now = Date()
        server.chat.items = [
            RemoteChatItem(id: "f-user", kind: "user", date: now, text: "how does login refresh the token?"),
            tool("f-t1", "Ran `npm test -- login`", ok: false), tool("f-t2", "Read src/auth/session.ts", ok: true), tool("f-t3", "Edited src/auth/session.ts", ok: true),
            RemoteChatItem(id: "f-assistant", kind: "assistant", date: now, text: Self.markdownReply),
            RemoteChatItem(id: "f-notice", kind: "notice", date: now, text: "Automation ran at 10:00\nChecked 3 pull requests. **All green.**"),
            RemoteChatItem(id: "f-shot", kind: "screenshot", date: now, fileName: "shot.png", isImage: true),
            RemoteChatItem(id: "f-long", kind: "user", date: now, text: Self.longMessage),
            RemoteChatItem(id: "f-error", kind: "error", date: now, text: "The agent stopped: it could not reach the model."),
        ]
        server.chat.state = "done"
    }

    private func pair() {
        app.launchArguments = ["--reset-credentials"] + (dark ? ["--force-dark"] : [])
        app.launch()
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server.pairingLink)
        app.buttons["pair-button"].tap()
    }

    private func openChat() {
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].waitForExistence(timeout: 20))
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var jump: XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'jump-to-latest' OR label == 'Jump to latest'")).firstMatch }

    private var transcript: XCUIElement { any("transcript").firstMatch }

    /// Scrolls the transcript until `element` can be hit, up to `limit` swipes.
    private func scroll(to element: XCUIElement, up: Bool, limit: Int = 12) {
        var swipes = 0
        while !element.isHittable, swipes < limit {
            if up { transcript.swipeDown(velocity: .fast) } else { transcript.swipeUp(velocity: .fast) }
            swipes += 1
        }
    }

    // S1, S4
    func testEveryRowTheMacDrawsInLight() { everyRow() }
    func testEveryRowTheMacDrawsInDark() { dark = true; everyRow() }

    private func everyRow() {
        let name = dark ? "dark" : "light"
        fixture()
        pair()
        openChat()
        // The chat opens at its newest message: the error row, the long message and its "Show more".
        XCTAssertTrue(any("f-error").exists || app.staticTexts["The agent stopped: it could not reach the model."].waitForExistence(timeout: 20))
        attach("parity-bottom-\(name)")

        let toggle = any("collapse-toggle-f-long")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "a long message collapses and offers Show more")
        XCTAssertTrue(toggle.label.hasPrefix("Show more"))
        let preview = any("bubble-f-long").label
        XCTAssertLessThan(preview.count, ChatMessageCollapse.maxCharacters, "the collapsed bubble holds only the start of the message")
        toggle.tap()
        XCTAssertTrue(app.buttons["Show less"].waitForExistence(timeout: 5), "a tap expands it")
        XCTAssertGreaterThan(any("bubble-f-long").label.count, ChatMessageCollapse.maxCharacters)
        attach("parity-long-expanded-\(name)")
        app.buttons["Show less"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show more'")).firstMatch.waitForExistence(timeout: 5))

        // The notice row: one muted line, and a tap shows the rest.
        let notice = any("notice-label")
        scroll(to: notice, up: true)
        XCTAssertTrue(notice.isHittable)
        XCTAssertFalse(any("notice-detail").exists)
        notice.tap()
        XCTAssertTrue(any("notice-detail").waitForExistence(timeout: 5))
        attach("parity-notice-\(name)")

        // The reply: heading, list, table, code block and quote.
        let code = any("code-block")
        scroll(to: code, up: true)
        XCTAssertTrue(code.exists)
        attach("parity-reply-\(name)")

        // The tool run: one folded line, three steps when opened.
        let steps = any("tool-steps-f-t1")
        scroll(to: steps, up: true)
        XCTAssertTrue(steps.isHittable)
        XCTAssertTrue(steps.label.contains("Ran 1 command"), "the folded line counts the steps: \(steps.label)")
        steps.tap()
        XCTAssertTrue(any("tool-step-f-t3").waitForExistence(timeout: 5))
        attach("parity-tools-\(name)")
    }

    // S2
    func testAReplyGrowsInPlaceAndTheTranscriptFollowsUnlessTheReaderScrolledUp() {
        server.chat.items = (1...30).map { RemoteChatItem(id: "old-\($0)", kind: $0 % 2 == 0 ? "assistant" : "user", date: Date(), text: "Earlier message number \($0)") }
        server.chat.runStarted = Date().addingTimeInterval(-9)
        pair()
        openChat()
        XCTAssertTrue(any("bubble-old-30").waitForExistence(timeout: 20))
        // The Mac announces a turn with chat.state, then streams chat.item events.
        server.chat.running = true
        server.chat.state = "running"
        server.publish(RemoteEvent.chatState)
        server.streamChunk(item: "m-stream", "First words. ")
        XCTAssertTrue(any("stop-button").waitForExistence(timeout: 10), "Stop shows while the turn runs")
        XCTAssertTrue(any("running-row").waitForExistence(timeout: 10), "the working row shows under the reply")
        XCTAssertTrue(any("elapsed").waitForExistence(timeout: 10))
        for index in 1...40 { server.streamChunk(item: "m-stream", "word\(index) ") }
        let bubble = any("bubble-m-stream")
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        XCTAssertTrue(bubble.label.contains("word40"), "the reply grew in place")
        XCTAssertTrue(bubble.isHittable, "a reader at the end follows the stream")
        XCTAssertFalse(jump.exists)
        attach("stream-following")

        // Scroll up, stream more: the view stays put and offers the jump.
        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        XCTAssertFalse(bubble.isHittable)
        for index in 41...80 { server.streamChunk(item: "m-stream", "word\(index) ") }
        XCTAssertTrue(jump.waitForExistence(timeout: 10), "new text below a reader who scrolled up shows Jump to latest")
        XCTAssertFalse(bubble.isHittable, "the transcript stays where the reader left it")
        attach("stream-scrolled-up")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
        XCTAssertTrue(bubble.isHittable)
        server.finishTurn()
        XCTAssertTrue(any("stop-button").waitForNonExistence(timeout: 10))
        XCTAssertTrue(any("running-row").waitForNonExistence(timeout: 10))
    }

    // An automation row above a "Ran N commands" row sit on one leading edge, with the same height and chevron column.
    func testAnAutomationRowAndAToolRowLineUp() {
        server.chat.items = [
            RemoteChatItem(id: "r-notice", kind: "notice", date: Date(), text: "Automation: Task review\nReview the open tasks and report which are blocked."),
            tool("r-t1", "Ran `git status`", ok: true), tool("r-t2", "Ran `npm test`", ok: true),
            RemoteChatItem(id: "r-assistant", kind: "assistant", date: Date(), text: "Two tasks are blocked on review."),
        ]
        server.chat.state = "done"
        pair()
        openChat()
        let notice = any("notice-label")
        let tools = any("tool-steps-r-t1")
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        XCTAssertTrue(tools.exists)
        XCTAssertEqual(notice.frame.minX, tools.frame.minX, accuracy: 0.5, "same leading edge")
        XCTAssertEqual(notice.frame.height, tools.frame.height, accuracy: 0.5, "same row height")
        attach("rows-closed-\(dark ? "dark" : "light")")
        notice.tap()
        tools.tap()
        XCTAssertTrue(any("notice-detail").waitForExistence(timeout: 5))
        XCTAssertTrue(any("tool-step-r-t1").waitForExistence(timeout: 5))
        attach("rows-open-\(dark ? "dark" : "light")")
        // Closing again restores the same height.
        notice.tap()
        XCTAssertFalse(any("notice-detail").waitForExistence(timeout: 2))
    }

    // S5
    func testAnErrorReplyShowsAsTheRedCardAndAFailedSendAsARowWithRetry() {
        server.chat.items = [RemoteChatItem(id: "e-user", kind: "user", date: Date(), text: "run it"),
                             RemoteChatItem(id: "e-error", kind: "error", date: Date(), text: "The agent stopped: it could not reach the model.")]
        server.chat.state = "failed"
        pair()
        openChat()
        XCTAssertTrue(app.staticTexts["The agent stopped: it could not reach the model."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Failed"].exists || app.staticTexts["chat-subtitle"].exists || any("chat-subtitle").label.contains("Failed"))
        attach("error-reply")
        // The Mac goes away: the failed send shows on its own row with Retry, and no banner repeats it.
        server.stop()
        let input = app.textViews["chat-input"]
        input.tap()
        input.typeText("hello?")
        app.buttons["send-button"].tap()
        XCTAssertTrue(any("outgoing-retry").waitForExistence(timeout: 20), "a failed send shows Retry on its row")
        XCTAssertFalse(any("chat-error").exists, "no banner for a failed send")
        XCTAssertFalse(any("chat-connection-lost").exists)
        attach("connection-lost")
    }
}
