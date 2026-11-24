import IronPetKit
import XCTest

/// The Tasks tab's quick filter chips, against the mock Mac.
final class QuickFilterUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer(tasks: [
            RemoteTask(id: "t-epic", title: "Plan the epic launch", status: .inProgress, labels: ["project": "epic"]),
            RemoteTask(id: "t-needs", title: "Review the contract", status: .needsYou),
            RemoteTask(id: "t-band", title: "Band rehearsal", status: .backlog, labels: ["project": "band"]),
        ], suggestions: [])
        server.taskFilters = [
            QuickFilter(id: "epic", name: "Epic", query: .object(["label": .object(["project": .string("epic")])]), order: 0),
            QuickFilter(id: "mine", name: "Needs me", query: .object(["status": .string("needs_you")]), order: 1),
        ]
        try server.start()
        app = XCUIApplication()
        app.launchArguments = ["--reset-credentials", "--auto-unlock"]
    }

    override func tearDown() { server.stop() }

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

    /// The inline title sits above the chip row, and the chips do not cover the first list row.
    func testTheTitleIsAboveTheChipsAtRest() {
        pairAndOpenTasks()
        let all = app.buttons["quick-filter-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 30))
        let title = app.navigationBars["Tasks"].staticTexts["Tasks"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        attach("tasks-at-rest")
        let bar = app.navigationBars["Tasks"]
        XCTAssertTrue(app.collectionViews.firstMatch.buttons["quick-filter-all"].exists,
                      "the chips are rows of the list, not a bar pinned over it, so the title cannot scroll under them")
        XCTAssertLessThanOrEqual(title.frame.maxY, all.frame.minY, "the Tasks title ends above the chip row")
        XCTAssertLessThanOrEqual(bar.frame.maxY, all.frame.minY + 1, "the chip row starts below the whole navigation bar")
        let firstRow = app.buttons["task-t-needs"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(firstRow.frame.minY, all.frame.maxY, "the chips do not cover the first row")
    }

    /// The Board view keeps the title above the chips too.
    func testTheTitleIsAboveTheChipsInBoardMode() {
        pairAndOpenTasks()
        let all = app.buttons["quick-filter-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 30))
        let board = app.segmentedControls["tasks-view-mode"].buttons["Board"]
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        let title = app.navigationBars["Tasks"].staticTexts["Tasks"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        attach("tasks-board-at-rest")
        XCTAssertLessThanOrEqual(title.frame.maxY, all.frame.minY, "the Tasks title ends above the chip row in Board mode")
        XCTAssertLessThanOrEqual(app.navigationBars["Tasks"].frame.maxY, all.frame.minY + 1, "the chip row starts below the whole navigation bar in Board mode")
    }

    /// The title is inline, so scrolling does not change the bar, and the chips scroll with the content instead of covering rows.
    func testScrollingKeepsTheBarAndTheChipsNeverCoverRows() {
        server.tasks = (1...30).map { RemoteTask(id: "t-\($0)", title: "Task number \($0)", status: .backlog) }
        pairAndOpenTasks()
        let all = app.buttons["quick-filter-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 30))
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let bar = app.navigationBars["Tasks"]
        let restHeight = bar.frame.height
        for _ in 0..<3 { list.swipeUp() }
        attach("tasks-scrolled")
        XCTAssertEqual(bar.frame.height, restHeight, accuracy: 1, "the inline bar keeps its height while the list scrolls")
        let visibleRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-t-'")).allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(visibleRows.isEmpty)
        if all.exists && all.isHittable {
            for row in visibleRows { XCTAssertFalse(row.frame.intersects(all.frame), "a visible chip never covers a row") }
        }
    }

    /// Pulling the list down asks the Mac for the tasks again.
    func testPullToRefreshReloads() {
        pairAndOpenTasks()
        XCTAssertTrue(app.buttons["quick-filter-all"].waitForExistence(timeout: 30))
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let before = server.requests.count
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        let deadline = Date().addingTimeInterval(15)
        while server.requests.count == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertGreaterThan(server.requests.count, before, "pulling down asks the Mac for the tasks again")
        XCTAssertTrue(app.buttons["task-t-needs"].waitForExistence(timeout: 10))
    }

    /// S4
    func testTheChipsShowAndFilterTheListAndRemoveCallsTheMac() {
        pairAndOpenTasks()
        let all = app.buttons["quick-filter-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["quick-filter-epic"].exists)
        XCTAssertTrue(app.buttons["quick-filter-mine"].exists)
        XCTAssertTrue(app.buttons["task-t-needs"].waitForExistence(timeout: 10), "All shows every task")
        XCTAssertTrue(app.buttons["task-t-band"].exists)

        app.buttons["quick-filter-epic"].tap()
        XCTAssertTrue(app.buttons["task-t-epic"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["task-t-needs"].exists, "the epic filter leaves out the other tasks")
        XCTAssertFalse(app.buttons["task-t-band"].exists)
        attach("quick-filter-epic")

        app.buttons["quick-filter-mine"].tap()
        XCTAssertTrue(app.buttons["task-t-needs"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["task-t-epic"].exists)

        app.buttons["quick-filter-epic"].press(forDuration: 1.0)
        let remove = app.buttons["Remove…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Edit…"].exists)
        remove.tap()
        // The dialog's button can match twice (its own label and the identifier), so take the first match.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Remove")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the removal asks first")
        XCTAssertFalse(server.requests.contains { $0.line.hasPrefix("DELETE /v1/task-filters") }, "nothing is deleted before the confirmation")
        confirm.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["quick-filter-epic"])
        waitForExpectations(timeout: 15)
        XCTAssertTrue(server.requests.contains { $0.line == "DELETE /v1/task-filters/epic" })
        XCTAssertTrue(app.buttons["quick-filter-mine"].exists)
    }

    /// S5
    func testAddSendsThePromptToTheMainChatAndOpensTheChat() {
        pairAndOpenTasks()
        let add = app.buttons["quick-filter-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let field = app.textFields["quick-filter-description"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("epic tasks not done")
        attach("quick-filter-sheet")
        app.buttons["quick-filter-send"].tap()
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 10))
        let sent = NSPredicate { _, _ in
            self.server.requests.contains { $0.line == "POST /v1/chat/current/messages" && $0.json["text"] as? String == "Create a task quick filter: epic tasks not done" }
        }
        expectation(for: sent, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.tabBars.buttons["Chat"].isSelected, "the app switches to the chat")
    }

    func testEditFromAChipSendsTheIdAndTheCurrentQuery() {
        pairAndOpenTasks()
        XCTAssertTrue(app.buttons["quick-filter-epic"].waitForExistence(timeout: 30))
        app.buttons["quick-filter-epic"].press(forDuration: 1.0)
        let edit = app.buttons["Edit…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let field = app.textFields["quick-filter-description"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("epic tasks not done")
        app.buttons["quick-filter-send"].tap()
        let expected = #"Change the task quick filter "Epic" (id epic, current query {"label":{"project":"epic"}}): epic tasks not done"#
        let sent = NSPredicate { _, _ in
            self.server.requests.contains { $0.line == "POST /v1/chat/current/messages" && $0.json["text"] as? String == expected }
        }
        expectation(for: sent, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
    }

    /// S3
    func testThePickedFilterSurvivesSwitchingTabsAndARelaunch() {
        pairAndOpenTasks()
        XCTAssertTrue(app.buttons["quick-filter-epic"].waitForExistence(timeout: 30))
        app.buttons["quick-filter-epic"].tap()
        XCTAssertTrue(app.buttons["task-t-epic"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["task-t-band"].exists)

        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(app.tabBars.buttons["Chat"].isSelected)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.buttons["quick-filter-epic"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["quick-filter-epic"].isSelected, "the same chip is still selected after another tab")
        XCTAssertTrue(app.buttons["task-t-epic"].exists)
        XCTAssertFalse(app.buttons["task-t-band"].exists)
        attach("quick-filter-after-tab-switch")

        // Relaunch without --reset-credentials: the pairing and the stored filter stay.
        app.terminate()
        app.launchArguments = ["--auto-unlock"]
        app.launch()
        let tab = app.tabBars.buttons["Tasks"]
        XCTAssertTrue(tab.waitForExistence(timeout: 60))
        tab.tap()
        XCTAssertTrue(app.buttons["quick-filter-epic"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["quick-filter-epic"].isSelected, "the same chip is selected after a relaunch")
        XCTAssertTrue(app.buttons["task-t-epic"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["task-t-band"].exists)
    }

    func testAnOlderMacShowsNoChips() {
        server.taskFiltersSupported = false
        pairAndOpenTasks()
        XCTAssertTrue(app.buttons["task-t-needs"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["quick-filter-all"].exists)
        XCTAssertFalse(app.buttons["quick-filter-add"].exists)
    }
}
