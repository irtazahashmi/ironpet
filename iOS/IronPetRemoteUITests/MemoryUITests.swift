import IronPetKit
import XCTest

/// The Memory screen behind the More tab, against the mock Mac.
final class MemoryUITests: XCTestCase {
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

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openMemory() {
        app.launch()
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server.pairingLink)
        app.buttons["pair-button"].tap()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let row = app.buttons["more-memory"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    func testBrowseFilterOpenAPageAndFollowALink() {
        openMemory()
        XCTAssertTrue(app.buttons["memory-row-page_4e91b0"].waitForExistence(timeout: 20))
        attach("memory-list")
        app.buttons["memory-chip-people"].tap()
        XCTAssertTrue(app.buttons["memory-row-page_9594cc"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["memory-row-page_4e91b0"].exists)
        app.buttons["memory-chip-people"].tap()
        app.buttons["memory-row-page_4e91b0"].tap()
        let link = app.buttons["memory-link-page_9594cc"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        attach("memory-page")
        link.tap()
        XCTAssertTrue(app.navigationBars["Maya Chen"].waitForExistence(timeout: 10), "following a link pushes the linked page")
    }
}
