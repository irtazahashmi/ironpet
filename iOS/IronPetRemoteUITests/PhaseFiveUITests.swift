import IronPetKit
import XCTest

/// The Screen screen behind the More tab, against the mock Mac.
final class PhaseFiveUITests: XCTestCase {
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

    private func pairAndOpenScreen() {
        app.launch()
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server.pairingLink)
        app.buttons["pair-button"].tap()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let row = app.buttons["more-screen"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // S5: this test reads the screen text on the phone. The container check in the verify notes looks for the strings below on disk.
    func testStatusChangesOutlineSearchAndPause() {
        pairAndOpenScreen()
        XCTAssertTrue(any("screen-status").waitForExistence(timeout: 20))
        XCTAssertTrue(any("screen-change-c12").waitForExistence(timeout: 10))
        attach("screen")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("release\n")
        XCTAssertTrue(any("screen-hit-12").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '[redacted:'")).firstMatch.exists)
        any("screen-hit-12").tap()
        XCTAssertTrue(any("screen-capture-text").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'review PR 4649'")).firstMatch.exists)

        XCTAssertGreaterThan(server.count("GET /v1/screen/search"), 0)
    }

    func testPausingFromThePhone() {
        pairAndOpenScreen()
        XCTAssertTrue(any("pause-15").waitForExistence(timeout: 20))
        any("pause-15").tap()
        let paused = NSPredicate { _, _ in self.server.count("POST /v1/screen/pause") == 1 }
        wait(for: [XCTNSPredicateExpectation(predicate: paused, object: nil)], timeout: 10)
        XCTAssertTrue(any("screen-notice").waitForExistence(timeout: 10))
    }

    func testAMacWithoutTheScopeExplainsWhereToTurnItOn() {
        server.screenAllowed = false
        pairAndOpenScreen()
        XCTAssertTrue(any("screen-forbidden").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Screen text is off for this phone"].exists)
        XCTAssertFalse(any("screen-status").exists)
    }
}
