import IronPetKit
import XCTest

/// The recording bar of the iPhone chat. `--fake-voice` swaps the microphone for a pulsing tone and the voice socket for one that
/// accepts everything, because a simulator has neither a microphone nor a voice socket on the mock server. That nothing reaches
/// the Mac after a cancel is asserted in PhaseSixTests, against a fake channel.
final class VoiceRecordingUITests: XCTestCase {
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

    private func openChat(appearance: String = "light") {
        app.launchArguments = ["--reset-credentials", "--fake-voice"] + (appearance == "dark" ? ["--force-dark"] : [])
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.appears(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].appears(timeout: 20))
    }

    func testRecordingShowsTheWaveformAndATimerInLightAndDark() {
        for appearance in ["light", "dark"] {
            app.terminate()
            openChat(appearance: appearance)
            app.buttons["mic-button"].tap()
            XCTAssertTrue(app.otherElements["voice-recording-bar"].appears(timeout: 10))
            let timer = app.staticTexts["Recording time"]
            XCTAssertTrue(timer.appears(timeout: 5))
            XCTAssertNotNil(timer.value as? String)
            let counting = NSPredicate { _, _ in (timer.value as? String) != "0:00" }
            let counted = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: counting, object: nil)], timeout: 5)
            XCTAssertEqual(counted, .completed, "the timer counts up")
            attach("recording-\(appearance)")
            app.buttons["voice-cancel"].tap()
        }
    }

    func testCancelReturnsToTheNormalComposerAndStopRecordsAsBefore() {
        openChat()
        app.buttons["mic-button"].tap()
        XCTAssertTrue(app.buttons["voice-cancel"].appears(timeout: 10))
        XCTAssertEqual(app.buttons["voice-cancel"].label, "Cancel recording")
        XCTAssertEqual(app.buttons["mic-button"].label, "Stop recording")
        app.buttons["voice-cancel"].tap()
        XCTAssertTrue(app.textViews["chat-input"].appears(timeout: 5), "the composer is back")
        XCTAssertFalse(app.buttons["voice-cancel"].exists)
        XCTAssertEqual(app.buttons["mic-button"].label, "Dictate")

        app.buttons["mic-button"].tap()
        XCTAssertTrue(app.buttons["voice-cancel"].appears(timeout: 10))
        app.buttons["mic-button"].tap()
        XCTAssertFalse(app.buttons["voice-cancel"].appears(timeout: 1), "Stop ends the recording and the bar goes")
    }
}
