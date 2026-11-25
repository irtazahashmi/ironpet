import IronPetKit
import XCTest

/// No chat state changes the height or position of anything in the transcript. A message shows its state on its bubble, and the
/// working row has its final size from the first frame.
final class ChatSendStatesUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    private func launch(dark: Bool = false) {
        app.launchArguments = ["--reset-credentials", "--auto-unlock", "--network-strip-delay", "3", "--network-retry-ms", "100"] + (dark ? ["--force-dark"] : [])
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

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func attach(_ name: String, dark: Bool) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name)-\(dark ? "dark" : "light")"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func send(_ text: String) {
        let input = app.textViews["chat-input"]
        input.tap()
        input.typeText(text)
        app.buttons["send-button"].tap()
    }

    /// The frame of the one bubble that holds `text`.
    private func bubble(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'bubble-' AND label CONTAINS %@", text)).firstMatch
    }

    private func assertSame(_ a: CGRect, _ b: CGRect, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 0.5, message, file: file, line: line)
    }

    // S1
    func testASendingMessageIsDimmedWithNoTextAndKeepsItsFrameWhenConfirmed() {
        for dark in [false, true] {
            if dark { app.terminate(); app = XCUIApplication() }
            launch(dark: dark)
            server.sendDelay = 3
            send("sending state \(dark)")
            let sending = bubble("sending state \(dark)")
            XCTAssertTrue(sending.waitForExistence(timeout: 10))
            XCTAssertEqual(sending.value as? String, "Sending", "VoiceOver reads the state")
            XCTAssertFalse(app.staticTexts["Sending…"].exists, "no text row")
            let before = sending.frame
            attach("message-sending", dark: dark)
            // The Mac's copy replaces the pending bubble. Look it up again until it is there and no longer reads "Sending". A failed
            // snapshot counts as "not yet", since the element can vanish for a moment while the row is replaced.
            let rows = { self.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'bubble-' OR identifier BEGINSWITH 'queued-' OR identifier == 'outgoing-delivered'")).allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)|\($0.value ?? "nil")" } }
            let deadline = Date().addingTimeInterval(45)
            var settled = false
            while Date() < deadline, !settled {
                if let snapshot = try? bubble("sending state \(dark)").snapshot() { settled = (snapshot.value as? String ?? "") != "Sending" }
                if !settled { Thread.sleep(forTimeInterval: 0.3) }
            }
            XCTAssertTrue(settled, "the message is confirmed. Rows: \(rows())")
            // The mock starts a turn when it confirms, and the transcript follows the new working row, so only the height is stable here.
            XCTAssertEqual(before.height, bubble("sending state \(dark)").frame.height, accuracy: 0.5, "the bubble does not resize when it is confirmed")
            XCTAssertEqual(before.minX, bubble("sending state \(dark)").frame.minX, accuracy: 0.5)
            attach("message-confirmed", dark: dark)
            server.sendDelay = 0
            // The mock started a turn. End it, or the next message waits in the Mac's queue.
            server.finishTurn()
            XCTAssertTrue(any("running-row").waitForNonExistence(timeout: 10))
        }
    }

    // S2
    func testAFailedMessageHasARetryButtonBesideItAndNoRowBelow() { failedMessage(dark: false) }
    func testAFailedMessageHasARetryButtonBesideItAndNoRowBelowInDark() { failedMessage(dark: true) }

    private func failedMessage(dark: Bool) {
        launch(dark: dark)
        server.brokenRoutes = ["/v1/chat/current/messages": 500]
        send("will fail")
        let retry = app.buttons["outgoing-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        XCTAssertEqual(retry.label, "Retry sending")
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        let failed = bubble("will fail")
        XCTAssertTrue((failed.value as? String ?? "").hasPrefix("Not sent"), "VoiceOver reads the failure")
        XCTAssertFalse(any("outgoing-failed").exists, "no row below the bubble")
        XCTAssertLessThanOrEqual(retry.frame.maxX, failed.frame.minX + 8, "the button sits beside the bubble, clear of the source label and the time under it")
        attach("message-failed", dark: dark)
        let before = failed.frame
        server.brokenRoutes = [:]
        retry.tap()
        XCTAssertTrue(any("outgoing-delivered").waitForExistence(timeout: 20))
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(bubble("will fail").frame.height, before.height, accuracy: 0.5, "the bubble keeps its height when it recovers")
        XCTAssertFalse((bubble("will fail").value as? String ?? "").hasPrefix("Not sent"), "the failure is gone")
    }

    // S4
    func testTheWorkingRowKeepsItsSizeWhenTheElapsedTimeStarts() { workingRow(dark: false) }
    func testTheWorkingRowKeepsItsSizeWhenTheElapsedTimeStartsInDark() { workingRow(dark: true) }

    private func workingRow(dark: Bool) {
        server.chat.items = (1...6).map { RemoteChatItem(id: "old-\($0)", kind: $0 % 2 == 0 ? "assistant" : "user", date: Date(), text: "Earlier message number \($0)") }
        launch(dark: dark)
        XCTAssertTrue(bubble("Earlier message number 6").waitForExistence(timeout: 20))
        server.chat.running = true
        server.chat.state = "running"
        server.chat.runStarted = nil
        server.publish(RemoteEvent.chatState)
        let row = any("running-row")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+s'")).firstMatch.exists, "the time is empty before the turn start arrives")
        let above = bubble("Earlier message number 6").frame
        let before = row.frame
        attach("working-before-start", dark: dark)
        server.chat.runStarted = Date().addingTimeInterval(-5)
        server.publish(RemoteEvent.chatState)
        let counting = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+s'")).firstMatch
        XCTAssertTrue(counting.waitForExistence(timeout: 10))
        assertSame(before, row.frame, "the working row keeps its place and height")
        XCTAssertEqual(above, bubble("Earlier message number 6").frame, "the rows above do not move")
        attach("working-counting", dark: dark)
    }

    // S7
    func testTheLongPressPreviewOfAMessageHasASolidRoundedBackground() {
        server.chat.items = [RemoteChatItem(id: "u-1", kind: "user", date: Date(), text: "A question with invented words"),
                             RemoteChatItem(id: "a-1", kind: "assistant", date: Date(), text: "An answer with **bold** invented words.")]
        for dark in [false, true] {
            if dark { app.terminate(); app = XCUIApplication() }
            launch(dark: dark)
            for (id, name) in [("u-1", "preview-user"), ("a-1", "preview-reply")] {
                let message = bubble(id == "u-1" ? "A question" : "An answer")
                XCTAssertTrue(message.waitForExistence(timeout: 20))
                message.press(forDuration: 1.2)
                XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "the menu keeps its items")
                if id == "a-1" { XCTAssertTrue(app.buttons["Select text"].exists, "Select text stays on a reply") }
                attach(name, dark: dark)
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
                XCTAssertTrue(app.buttons["Copy"].waitForNonExistence(timeout: 5))
            }
        }
    }

    // S8
    func testAnUnreachableMacShowsOneStripAndNoErrorRowInChat() { oneStrip(dark: false) }
    func testAnUnreachableMacShowsOneStripAndNoErrorRowInChatInDark() { oneStrip(dark: true) }

    private func oneStrip(dark: Bool) {
        launch(dark: dark)
        server.stop()
        send("typed while away")
        XCTAssertTrue(any("network-strip").waitForExistence(timeout: 20))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "network-strip").count, 1)
        XCTAssertFalse(any("chat-error").exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH \"Can't reach your Mac\" AND label CONTAINS \"Retrying\"")).firstMatch.exists)
        attach("chat-one-strip", dark: dark)
    }

    // S7
    func testTheLongPressPreviewOfAFailedMessageIsRedLikeItsBubble() {
        launch()
        server.brokenRoutes = ["/v1/chat/current/messages": 500]
        send("preview of a failure")
        XCTAssertTrue(app.buttons["outgoing-retry"].waitForExistence(timeout: 20))
        bubble("preview of a failure").press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5), "the menu offers Retry")
        attach("preview-failed", dark: false)
    }
}
