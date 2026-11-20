import XCTest

/// The mock server runs in the test runner. The app reaches it over the simulator's loopback.
final class IronPetRemoteUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
        app.launchArguments = ["--reset-credentials"]
    }

    override func tearDown() { server.stop() }

    private func paste(_ link: String) {
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(link)
        app.buttons["pair-button"].tap()
    }

    /// S1
    func testPairingByLinkShowsTheTasksInTheirSections() {
        app.launch()
        paste(server.pairingLink)

        let needs = app.staticTexts["section-needs-you"]
        XCTAssertTrue(needs.waitForExistence(timeout: 20), "the Tasks tab opens after Allow")
        XCTAssertTrue(app.staticTexts["section-suggestions"].exists)
        XCTAssertTrue(app.staticTexts["Send the notes to Bo"].exists)

        // The list is lazy, so scroll until the next header is on screen. A row must sit below its own header and above the next one.
        func header(_ id: String) -> XCUIElement { app.staticTexts["section-\(id)"] }
        func row(_ id: String) -> XCUIElement { app.buttons["task-\(id)"] }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<6 where !element.exists || !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.exists, "\(element) is in the list")
        }
        let order = [("needs-you", "t-needs", "in-progress"), ("in-progress", "t-progress", "backlog"), ("backlog", "t-backlog", "waiting")]
        for (name, id, next) in order {
            reveal(header(next))
            let item = row(id)
            XCTAssertTrue(item.exists, "\(id) is listed")
            XCTAssertGreaterThan(item.frame.minY, header(name).frame.minY, "\(id) sits below \(name)")
            XCTAssertLessThan(item.frame.minY, header(next).frame.minY, "\(id) sits above \(next)")
        }
        reveal(row("t-waiting"))
        XCTAssertGreaterThan(row("t-waiting").frame.minY, header("waiting").frame.minY)
        let done = app.buttons["section-done"]
        reveal(done)
        XCTAssertFalse(row("t-done").exists, "Done starts collapsed")
        done.tap()
        reveal(row("t-done"))
    }

    /// S2
    func testDenialIsShownOnThePairingScreen() {
        server.outcome = .deny
        app.launch()
        paste(server.pairingLink)
        XCTAssertTrue(app.staticTexts["The Mac denied this device."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["pair-button"].exists, "still on the pairing screen")
        XCTAssertFalse(app.staticTexts["section-needs-you"].exists)
    }

    func testShowsWaitingForAllowUntilCancelled() {
        server.pendingPolls = 100_000
        app.launch()
        paste(server.pairingLink)
        XCTAssertTrue(app.staticTexts["Waiting for Allow on your Mac"].waitForExistence(timeout: 20))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["pair-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Waiting for Allow on your Mac"].exists)
    }

    /// S8, run by hand against a `--test-mode` Mac build: `TEST_RUNNER_IRONPET_REAL_LINK=<link> xcodebuild test ...`. Skipped without the link.
    func testPairsWithARealMacAndAddsASuggestion() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["IRONPET_REAL_LINK"] == nil, "set TEST_RUNNER_IRONPET_REAL_LINK to run this against a Mac")
        let link = ProcessInfo.processInfo.environment["IRONPET_REAL_LINK"] ?? ""
        app.launch()
        paste(link)
        let addButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'add-'")).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 60), "the Mac's suggestion is listed after Allow")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "before-add"
        shot.lifetime = .keepAlways
        addButton.tap()
        XCTAssertTrue(app.staticTexts["section-backlog"].waitForExistence(timeout: 20), "the accepted suggestion became a backlog task")
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "after-add"
        after.lifetime = .keepAlways
        add(shot)
        add(after)
    }
}
