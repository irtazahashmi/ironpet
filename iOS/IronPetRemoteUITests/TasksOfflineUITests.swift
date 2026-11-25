import IronPetKit
import XCTest

/// Tasks keep working without the Mac: the list is there after a relaunch, and edits show at once and wait for the Mac.
final class TasksOfflineUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer(suggestions: [])
        try server.start()
        app = XCUIApplication()
        app.launchArguments = ["--reset-credentials", "--auto-unlock"]
    }

    override func tearDown() { server.stop() }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func pairAndOpenTasks() {
        app.launch()
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Tasks"]
        XCTAssertTrue(tab.waitForExistence(timeout: 60))
        tab.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// S1 and S2
    func testTheListSurvivesARelaunchWithoutTheMacAndEditsShowAtOnce() {
        pairAndOpenTasks()
        XCTAssertTrue(any("task-t-backlog").waitForExistence(timeout: 30))
        server.stop()

        // S2: a new task and a status change show without the Mac.
        any("new-task").tap()
        let title = app.textFields["task-title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Buy oat milk")
        app.buttons["task-save"].tap()
        XCTAssertTrue(app.staticTexts["Buy oat milk"].waitForExistence(timeout: 10), "the new task shows at once")

        any("task-t-backlog").tap()
        let actions = app.buttons["task-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Edit title and notes"].tap()
        let edit = app.textFields["task-title-field"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        edit.typeText(" today")
        app.buttons["task-save"].tap()
        XCTAssertTrue(app.staticTexts["Clean up the inbox today"].waitForExistence(timeout: 10), "the edited title shows at once")
        attach("tasks-offline-edited")

        // S1 and S5: the list and the waiting edits are there after a relaunch with the Mac still out of reach.
        app.terminate()
        app.launchArguments = ["--auto-unlock"]
        app.launch()
        let tab = app.tabBars.buttons["Tasks"]
        XCTAssertTrue(tab.waitForExistence(timeout: 60))
        tab.tap()
        XCTAssertTrue(app.staticTexts["Buy oat milk"].waitForExistence(timeout: 30), "the waiting task is still there")
        XCTAssertTrue(any("task-t-needs").exists, "the last list shows")
        XCTAssertTrue(app.staticTexts["Clean up the inbox today"].exists, "the waiting edit still shows")
        attach("tasks-offline-relaunched")
    }
}
