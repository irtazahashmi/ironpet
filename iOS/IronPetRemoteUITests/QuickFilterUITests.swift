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
