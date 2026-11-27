import IronPetKit
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
        app.enterPairingLink(link)
        app.buttons["pair-button"].tap()
    }

    private func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.appears(timeout: 20), "the \(name) tab exists after pairing")
        tab.tap()
    }

    /// S1
    func testPairingByLinkShowsTheInbox() {
        app.launch()
        paste(server.pairingLink)
        openTab("Inbox")

        XCTAssertTrue(app.staticTexts["Send the notes to Bo"].appears(timeout: 20), "the Inbox opens after Allow")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'MEETING'")).firstMatch.exists, "the items are grouped by origin")
        XCTAssertTrue(app.buttons["done-s-1"].exists)
        XCTAssertFalse(app.buttons["remove-s-1"].exists, "Remove is a swipe, not a button on the row")
        XCTAssertFalse(app.buttons["section-done"].exists, "there is no task list")

        app.buttons["done-s-1"].tap()
        XCTAssertTrue(app.staticTexts["Send the notes to Bo"].vanishes(timeout: 10), "Done takes the item off the list")
        app.descendants(matching: .any)["inbox-s-2"].swipeLeft()
        app.buttons["remove-s-2"].tap()
        XCTAssertTrue(app.staticTexts["Check the flaky build"].vanishes(timeout: 10), "Remove takes the item off the list")
        XCTAssertTrue(app.staticTexts["Inbox is empty"].appears(timeout: 10))
    }

    /// Phase 2: the Pet tab with Today, Agents and Alerts, against the mock. The screenshots go to the test results.
    func testPetAgentsAlertsAndTodayWorkAgainstTheMock() throws {
        server.setSprite(TestSheets.png(height: 2704))
        server.pet = RemotePet(name: "Ghost", mood: "idle", badge: 2, tricks: ["Wave", "Jump"])
        app.launch()
        paste(server.pairingLink)

        // Pet: the sprite, the bubble with buttons, the Mac-only bubble, a trick and Today.
        XCTAssertTrue(any("pet-sprite").appears(timeout: 20))
        XCTAssertTrue(any("pet-badge").appears(timeout: 10))
        XCTAssertTrue(app.buttons["bubble-action-act-open"].appears(timeout: 10))
        XCTAssertTrue(any("mac-only-approval:1").exists, "an approval bubble says Answer on the Mac")
        XCTAssertFalse(app.buttons["Allow"].exists)
        attach("pet")
        app.buttons["trick-Wave"].tap()
        let waved = NSPredicate { _, _ in self.server.count("POST /v1/pet/tricks/Wave") == 1 }
        wait(for: [XCTNSPredicateExpectation(predicate: waved, object: nil)], timeout: 10)
        app.buttons["bubble-action-act-open"].tap()
        XCTAssertTrue(app.buttons["bubble-action-act-open"].vanishes(timeout: 10), "pressing a button closes its bubble")
        let alertRow = app.buttons["today-item-i-alert"]
        // The pet hero (backdrop + sprite) is tall, so Today needs more swipes than a plain list.
        for _ in 0..<12 where !alertRow.exists || !alertRow.isHittable { app.swipeUp() }
        XCTAssertTrue(alertRow.appears(timeout: 5), "Today lists the brief")
        attach("today")
        alertRow.tap()
        XCTAssertTrue(app.buttons["dismiss-al-ci"].appears(timeout: 10), "an alert item opens Alerts behind More")
        attach("alerts")
        app.buttons["dismiss-al-ci"].tap()
        let gone = NSPredicate { _, _ in self.server.alerts.map(\.id) == ["al-pr"] }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 10)

        openTab("Agents")
        XCTAssertTrue(app.staticTexts["agents-section-needs-input"].appears(timeout: 10))
        attach("agents")
        app.buttons["agent-s-needs"].tap()
        XCTAssertTrue(app.buttons["ask-agent-button"].appears(timeout: 10))
        app.buttons["ask-agent-button"].tap()
        XCTAssertTrue(app.staticTexts["agent-notice"].appears(timeout: 10))
        XCTAssertEqual(server.count("POST /v1/agents/s-needs/ask"), 1)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// S2
    func testDenialIsShownOnThePairingScreen() {
        server.outcome = .deny
        app.launch()
        paste(server.pairingLink)
        XCTAssertTrue(app.staticTexts["The Mac denied this device."].appears(timeout: 20))
        XCTAssertTrue(app.buttons["pair-button"].exists, "still on the pairing screen")
        XCTAssertFalse(app.tabBars.buttons["Inbox"].exists)
    }

    func testShowsWaitingForAllowUntilCancelled() {
        server.pendingPolls = 100_000
        app.launch()
        paste(server.pairingLink)
        XCTAssertTrue(app.staticTexts["Waiting for Allow on your Mac"].appears(timeout: 20))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["pair-button"].appears(timeout: 5))
        XCTAssertFalse(app.staticTexts["Waiting for Allow on your Mac"].exists)
    }

    /// S8, run by hand against a `--test-mode` Mac build: `TEST_RUNNER_IRONPET_REAL_LINK=<link> xcodebuild test ...`. Skipped without the link.
    func testPairsWithARealMacAndFinishesAnInboxItem() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["IRONPET_REAL_LINK"] == nil, "set TEST_RUNNER_IRONPET_REAL_LINK to run this against a Mac")
        let link = ProcessInfo.processInfo.environment["IRONPET_REAL_LINK"] ?? ""
        app.launch()
        paste(link)
        openTab("Inbox")
        let doneButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'done-'")).firstMatch
        XCTAssertTrue(doneButton.appears(timeout: 60), "the Mac's inbox item is listed after Allow")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "before-add"
        shot.lifetime = .keepAlways
        doneButton.tap()
        XCTAssertTrue(doneButton.vanishes(timeout: 20), "the finished item left the Inbox")
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "after-add"
        after.lifetime = .keepAlways
        add(shot)
        add(after)
    }

    /// Phase 2 against a real `--test-mode` Mac, run by hand with `TEST_RUNNER_IRONPET_REAL_LINK` set. A script on the Mac side presses Allow,
    /// makes an alert and an agent session needing input, and watches that the Wave trick and the dismissal reach the Mac. Skipped without the link.
    func testPhaseTwoTabsAgainstARealMac() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["IRONPET_REAL_LINK"] == nil, "set TEST_RUNNER_IRONPET_REAL_LINK to run this against a Mac")
        let link = ProcessInfo.processInfo.environment["IRONPET_REAL_LINK"] ?? ""
        app.launch()
        paste(link)
        XCTAssertTrue(any("pet-sprite").appears(timeout: 60), "the Pet tab opens after Allow")
        XCTAssertTrue(app.buttons["trick-Wave"].appears(timeout: 30))
        sleep(3)
        attach("real-pet")
        app.buttons["trick-Wave"].tap()
        sleep(3)
        openTab("More")
        app.buttons["more-alerts"].tap()
        let dismiss = app.buttons["dismiss-s10-alert"]
        XCTAssertTrue(dismiss.appears(timeout: 30), "the alert made on the Mac is listed")
        attach("real-alerts")
        dismiss.tap()
        XCTAssertTrue(dismiss.vanishes(timeout: 20), "the list follows the Mac after the dismissal")
        openTab("Agents")
        XCTAssertTrue(app.staticTexts["agents-section-needs-input"].appears(timeout: 30))
        attach("real-agents")
        openTab("Pet")
        for _ in 0..<5 where !app.staticTexts["today-section-agents"].exists { app.swipeUp() }
        sleep(1)
        attach("real-today")
        openTab("Inbox")
        sleep(2)
        attach("real-inbox")
    }
}
