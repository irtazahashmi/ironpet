import IronPetKit
import XCTest

/// Every network state has one place on screen and none of them moves the content. The mock Mac runs in the test runner, so a test
/// stops and restarts it to drop and restore the connection. `--network-strip-delay` shortens the 10 s wait and `--network-retry-ms` the retry wait.
final class NetworkStatesUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    private func launch(dark: Bool = false, extra: [String] = []) {
        app.launchArguments = ["--reset-credentials", "--auto-unlock", "--network-strip-delay", "3", "--network-retry-ms", "100"] + (dark ? ["--force-dark"] : []) + extra
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        XCTAssertTrue(app.tabBars.buttons["Agents"].waitForExistence(timeout: 20))
    }

    /// The bubble of a message that waits for the connection. Its accessibility value says so, and the clock glyph is hidden from VoiceOver.
    private func waitingBubble() -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Waiting to send'")).firstMatch }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    private func attach(_ name: String, dark: Bool) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name)-\(dark ? "dark" : "light")"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The strip hides on the next event socket reconnect. The socket's back-off grows to 30 s while the Mac is down, and a slow CI runner
    /// keeps the Mac down longer, so the default wait is longer than the 20 s used to see a state appear.
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 45, _ message: String) {
        let gone = NSPredicate(format: "exists == false")
        let result = XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, message)
    }

    /// The error rows the screens used to show. None of them exists any more.
    private var errorRows: [String] { ["agents-error", "inbox-error", "alerts-error", "automations-error", "meetings-error", "screen-error", "settings-error", "pet-error", "chat-error"] }

    // S1, S2
    func testTheStripShowsOnEveryTabAfterTheDelayAndNothingMoves() {
        launch()
        openTab("Agents")
        let row = app.buttons["agent-s-needs"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the agent list loaded")
        let before = row.frame

        server.stop()
        // Under the delay nothing shows.
        sleep(1)
        XCTAssertFalse(any("network-strip").exists, "a drop under the delay shows nothing")
        XCTAssertTrue(any("network-strip").waitForExistence(timeout: 20), "the strip shows after the delay")
        XCTAssertTrue(app.staticTexts["Can't reach your Mac"].exists)
        XCTAssertEqual(row.frame, before, "the list did not move when the strip showed")
        for id in errorRows { XCTAssertFalse(any(id).exists, "\(id) is gone") }
        XCTAssertFalse(app.staticTexts["The request timed out."].exists)
        XCTAssertFalse(any("load-error").exists, "a screen that loaded keeps its data")

        let stripFrame = any("network-strip").frame
        for tab in ["Pet", "Chat", "Inbox", "More"] {
            openTab(tab)
            XCTAssertTrue(any("network-strip").waitForExistence(timeout: 5), "the strip shows on \(tab)")
            XCTAssertEqual(any("network-strip").frame, stripFrame, "the strip sits in the same place and has the same height on \(tab)")
        }

        try? server.start()
        openTab("Agents")
        waitUntilGone(any("network-strip"), "the strip hides when the Mac is back")
        XCTAssertEqual(row.frame, before, "the list did not move when the strip hid")
    }

    // S2
    func testADropShorterThanTheDelayNeverShowsTheStrip() throws {
        launch()
        openTab("Agents")
        XCTAssertTrue(app.buttons["agent-s-needs"].waitForExistence(timeout: 20))
        server.stop()
        sleep(1)
        try server.start()
        sleep(5)
        XCTAssertFalse(any("network-strip").exists, "the Mac was back before the strip's delay")
    }

    // S3
    func testEveryScreenReadsAgainAfterTheMacReturnsWithoutAPull() throws {
        launch()
        openTab("Agents")
        XCTAssertTrue(app.buttons["agent-s-needs"].waitForExistence(timeout: 20))
        server.stop()
        XCTAssertTrue(any("network-strip").waitForExistence(timeout: 20))
        let reads = server.count("GET /v1/agents")
        try server.start()
        waitUntilGone(any("network-strip"), "the strip hides")
        let deadline = Date().addingTimeInterval(15)
        while server.count("GET /v1/agents") == reads, Date() < deadline { usleep(100_000) }
        XCTAssertGreaterThan(server.count("GET /v1/agents"), reads, "Agents read again by itself")
    }

    // S4
    func testAScreenThatNeverLoadedShowsTheFullPageErrorWithRetry() {
        server.brokenRoutes = ["/v1/agents": 500]
        launch()
        openTab("Agents")
        XCTAssertTrue(any("load-error").waitForExistence(timeout: 20), "the full-page error shows")
        XCTAssertTrue(app.staticTexts["Can't reach your Mac"].exists)
        XCTAssertFalse(app.staticTexts["No agents"].exists, "not the empty state")
        XCTAssertFalse(any("agents-error").exists)

        server.brokenRoutes = [:]
        app.buttons["load-error-retry"].tap()
        XCTAssertTrue(app.buttons["agent-s-needs"].waitForExistence(timeout: 20), "Retry loads the screen")
        waitUntilGone(any("load-error"), "the error goes")
    }

    // S5
    func testAFailedMessageShowsTheMarkAndRetryAndDeliveryShowsACheck() {
        launch()
        openTab("Chat")
        let input = app.textViews["chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        server.brokenRoutes = ["/v1/chat/current/messages": 500]
        input.tap()
        input.typeText("hello there")
        app.buttons["send-button"].tap()
        XCTAssertTrue(app.buttons["outgoing-retry"].waitForExistence(timeout: 20), "the retry button sits on the message")
        XCTAssertFalse(any("chat-error").exists, "no row above the transcript")

        server.brokenRoutes = [:]
        app.buttons["outgoing-retry"].tap()
        XCTAssertTrue(any("outgoing-delivered").waitForExistence(timeout: 20), "the check shows once the Mac has the message")
        waitUntilGone(any("outgoing-retry"), "the retry button goes")
    }

    // S5
    func testAMessageTypedOfflineShowsTheClockUntilTheMacIsBack() throws {
        launch()
        openTab("Chat")
        let input = app.textViews["chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        server.stop()
        input.tap()
        input.typeText("written offline")
        app.buttons["send-button"].tap()
        XCTAssertTrue(waitingBubble().waitForExistence(timeout: 20), "the clock shows while it waits")
        XCTAssertTrue(any("network-strip").waitForExistence(timeout: 20))
        try server.start()
        XCTAssertTrue(any("outgoing-delivered").waitForExistence(timeout: 30), "it goes out and shows the check")
        waitUntilGone(waitingBubble(), "the clock goes")
    }

    // S6: one screenshot of each state, light and dark, for the pull request.
    func testScreenshotsOfEveryStateInLightAndDark() {
        for dark in [false, true] {
            if dark {
                app.terminate()
                server.stop()
                server = MockIronPetServer()
                try? server.start()
            }
            // Agents never loads in this launch, so it shows the full-page error.
            server.brokenRoutes = ["/v1/agents": 500]
            launch(dark: dark)
            openTab("Agents")
            XCTAssertTrue(any("load-error").waitForExistence(timeout: 20))
            attach("load-error", dark: dark)
            server.brokenRoutes = [:]
            app.buttons["load-error-retry"].tap()
            XCTAssertTrue(app.buttons["agent-s-needs"].waitForExistence(timeout: 20))

            openTab("Inbox")
            XCTAssertTrue(app.buttons["done-s-1"].waitForExistence(timeout: 20))
            attach("inbox", dark: dark)

            openTab("Chat")
            let input = app.textViews["chat-input"]
            XCTAssertTrue(input.waitForExistence(timeout: 20))
            server.brokenRoutes = ["/v1/chat/current/messages": 500]
            input.tap()
            input.typeText("hello there")
            app.buttons["send-button"].tap()
            XCTAssertTrue(any("outgoing-retry").waitForExistence(timeout: 20))
            attach("message-failed", dark: dark)
            server.brokenRoutes = [:]
            app.buttons["outgoing-retry"].tap()
            XCTAssertTrue(any("outgoing-delivered").waitForExistence(timeout: 20))
            attach("message-delivered", dark: dark)

            // The keyboard hides the tab bar, so start the app again. The pairing stays in the Keychain.
            app.terminate()
            app.launchArguments = app.launchArguments.filter { $0 != "--reset-credentials" }
            app.launch()
            openTab("Agents")
            XCTAssertTrue(app.buttons["agent-s-needs"].waitForExistence(timeout: 10))
            server.stop()
            XCTAssertTrue(any("network-strip").waitForExistence(timeout: 20))
            attach("strip-agents", dark: dark)
            openTab("Inbox")
            XCTAssertTrue(any("network-strip").waitForExistence(timeout: 5))
            attach("strip-inbox", dark: dark)
        }
    }
}
