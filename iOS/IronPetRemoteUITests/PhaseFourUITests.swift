import IronPetKit
import XCTest

/// The Automations, Meetings and Settings screens behind the More tab, against the mock Mac.
final class PhaseFourUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
        app.launchArguments = ["--reset-credentials", "--auto-unlock"]
    }

    override func tearDown() { server.stop() }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func pairAndOpenMore(_ entry: String) {
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.appears(timeout: 20))
        more.tap()
        let row = app.buttons[entry]
        XCTAssertTrue(row.appears(timeout: 10))
        row.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // S6
    func testAnAutomationThatNeedsApprovalSaysSoWithoutAButton() {
        pairAndOpenMore("more-automations")
        XCTAssertTrue(any("automation-water").appears(timeout: 20))
        XCTAssertTrue(any("approval-ci-watch").appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["Waiting for Approve on the Mac"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.buttons["Reject"].exists)
        XCTAssertFalse(any("approval-water").exists, "an approved automation shows no waiting line")
        attach("automations")

        // The Mac reports that the other one now waits too: the row follows the event.
        var changed = server.automations
        changed[0].approval = "pending"
        server.automations = changed
        server.publish(RemoteEvent.automationNeedsApproval, id: "water")
        XCTAssertTrue(any("approval-water").appears(timeout: 10))

        // The detail has history and log, and no Approve either.
        any("automation-ci-watch").tap()
        XCTAssertTrue(any("detail-approval").appears(timeout: 10))
        XCTAssertFalse(app.buttons["run-now"].exists, "a waiting automation cannot be run")
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertTrue(app.buttons["pause-resume"].exists)
        attach("automation-detail")
    }

    func testPausingAndTheNewAutomationRequestReachTheMac() {
        pairAndOpenMore("more-automations")
        let menu = app.buttons["new-automation-menu"]
        XCTAssertTrue(menu.appears(timeout: 10))
        // On the CI runner a plain tap() on this toolbar menu failed with "failed to scroll to visible" (kAXErrorCannotComplete),
        // and isHittable stayed false, although the button sat inside the screen. A tap at its centre does not scroll first.
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["new-automation-request"].tap()
        let field = app.textFields["automation-request-field"]
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        field.typeText("tell me when CI breaks")
        app.buttons["automation-request-send"].tap()
        let sent = NSPredicate { _, _ in self.server.count("POST /v1/automations/request") == 1 }
        wait(for: [XCTNSPredicateExpectation(predicate: sent, object: nil)], timeout: 10)
        XCTAssertTrue(any("automations-notice").appears(timeout: 10))

        any("automation-water").tap()
        let pause = app.buttons["pause-resume"]
        XCTAssertTrue(pause.appears(timeout: 10))
        pause.tap()
        let paused = NSPredicate { _, _ in self.server.count("POST /v1/automations/water/pause") == 1 }
        wait(for: [XCTNSPredicateExpectation(predicate: paused, object: nil)], timeout: 10)
    }

    // S7
    func testMeetingsOpenAfterTheUnlockAndStopRecordingWorks() {
        server.meetingState = RemoteMeetingState(phase: "recording", appName: "Zoom")
        pairAndOpenMore("more-meetings")
        XCTAssertTrue(any("meeting-2026-11-14-1400").appears(timeout: 20), "the list shows once the unlock passed")
        XCTAssertTrue(any("recording-state").exists)
        XCTAssertFalse(app.buttons["Start recording"].exists)
        attach("meetings")
        any("meeting-2026-11-14-1400").tap()
        XCTAssertTrue(any("meeting-text").appears(timeout: 10))
        app.segmentedControls["meeting-kind"].buttons["Transcript"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'secret-word'")).firstMatch.appears(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["stop-recording"].tap()
        let stopped = NSPredicate { _, _ in self.server.count("POST /v1/meetings/stop") == 1 }
        wait(for: [XCTNSPredicateExpectation(predicate: stopped, object: nil)], timeout: 10)
        app.buttons["lock-meetings"].tap()
        XCTAssertTrue(app.buttons["unlock-meetings"].appears(timeout: 10), "locking shows the lock screen again")
        XCTAssertFalse(any("meeting-2026-11-14-1400").exists)
    }

    func testSettingsChangeOnlyWhatTheMacAllows() {
        pairAndOpenMore("more-settings")
        let toggle = app.switches["reminders-paused"]
        XCTAssertTrue(toggle.appears(timeout: 20))
        // The switch sits at the right end of its row. A tap in the middle of the row lands on the label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let patched = NSPredicate { _, _ in self.server.config.reminders.paused }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: patched, object: nil)], timeout: 10)
        XCTAssertEqual(result, .completed, "requests: \(server.requests.map(\.line)) value: \(String(describing: toggle.value))")
        // The Chat text size section sits first, so the privacy rows are further down than the first screen.
        for _ in 0..<4 where !app.buttons["meetings-off"].exists { app.swipeUp() }
        XCTAssertFalse(app.switches["meetings-enabled"].exists, "the phone has no switch that turns meetings on")
        XCTAssertTrue(app.buttons["meetings-off"].exists)
        attach("settings")
    }
}
