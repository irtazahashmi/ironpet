import IronPetKit
import XCTest

/// The Tasks tab's Board view, against the mock Mac.
final class TasksBoardUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        var done = MockIronPetServer.sampleTasks.last!
        done.closed = Date()
        server = MockIronPetServer(tasks: Array(MockIronPetServer.sampleTasks.dropLast()) + [done], suggestions: [])
        try server.start()
        app = XCUIApplication()
        app.launchArguments = ["--reset-credentials", "--auto-unlock"]
    }

    override func tearDown() { server.stop() }

    private func pairAndOpenTasks() {
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Tasks"]
        XCTAssertTrue(tab.waitForExistence(timeout: 60))
        tab.tap()
    }

    private func choose(_ mode: String) {
        let button = app.segmentedControls["tasks-view-mode"].buttons[mode]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// S6
    func testTheBoardShowsTheColumnsAndTheChoiceIsRemembered() {
        pairAndOpenTasks()
        XCTAssertTrue(app.staticTexts["section-needs-you"].waitForExistence(timeout: 30), "the list is the default")
        choose("Board")
        XCTAssertTrue(app.descendants(matching: .any)["tasks-board"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["board-header-needs-you"].exists)
        XCTAssertTrue(app.buttons["task-t-needs"].exists)
        XCTAssertTrue(app.staticTexts["board-header-in-progress"].exists)
        attach("tasks-board")

        app.terminate()
        app.launchArguments = ["--auto-unlock"]
        app.launch()
        let tab = app.tabBars.buttons["Tasks"]
        XCTAssertTrue(tab.waitForExistence(timeout: 60))
        tab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks-board"].waitForExistence(timeout: 30), "the board is shown again after a relaunch")

        choose("List")
        XCTAssertTrue(app.staticTexts["section-needs-you"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForExistence(timeout: 60))
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["section-needs-you"].waitForExistence(timeout: 30), "the list is shown again after a relaunch")
    }

    private func restartServer(tasks: [RemoteTask]) throws {
        server.stop()
        server = MockIronPetServer(tasks: tasks, suggestions: [])
        try server.start()
    }

    private var columnIDs: [String] { ["needs-you", "in-progress", "backlog", "waiting", "done"] }

    private func assertSameWidth(_ message: String) {
        let widths = columnIDs.map { app.descendants(matching: .any)["board-column-\($0)"].frame.width }
        XCTAssertTrue(widths.allSatisfy { $0 > 0 }, "every column is laid out: \(widths)")
        XCTAssertEqual(widths.max()! - widths.min()!, 0, accuracy: 1, "\(message): \(widths)")
    }

    /// S1
    func testEmptyColumnsHaveTheSameWidthAsFullOnes() throws {
        try restartServer(tasks: [MockIronPetServer.sampleTasks[0]])
        pairAndOpenTasks()
        choose("Board")
        XCTAssertTrue(app.buttons["task-t-needs"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["board-header-in-progress"].exists, "an empty column keeps its header")
        assertSameWidth("an empty column is as wide as a full one")
        attach("tasks-board-empty-columns")
    }

    /// S2
    func testAllColumnsEmptyStillShowAtFullWidth() throws {
        try restartServer(tasks: [])
        pairAndOpenTasks()
        choose("Board")
        XCTAssertTrue(app.descendants(matching: .any)["tasks-board"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["board-header-needs-you"].waitForExistence(timeout: 10))
        assertSameWidth("all empty columns share one width")
        attach("tasks-board-all-empty")
    }

    /// S7
    func testDraggingACardToAnotherColumnReachesTheMac() {
        pairAndOpenTasks()
        choose("Board")
        let card = app.buttons["task-t-needs"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let target = app.descendants(matching: .any)["board-column-in-progress"]
        XCTAssertTrue(target.exists)
        let drop = target.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0, thenDragTo: drop)

        let end = Date().addingTimeInterval(20)
        while Date() < end, server.tasks.first(where: { $0.id == "t-needs" })?.status != .inProgress { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(server.tasks.first { $0.id == "t-needs" }?.status, .inProgress, "the update reached the Mac side")
        XCTAssertEqual(server.requests.last { $0.method == "PATCH" }?.line, "PATCH /v1/tasks/t-needs")
        attach("tasks-board-after-drag")
    }
}
