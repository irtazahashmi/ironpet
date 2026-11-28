import IronPetKit
import XCTest

/// The capsule above the message field opens the Mac's background work list as a sheet, and a row opens in place.
final class BackgroundWorkUITests: XCTestCase {
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

    func testTheCapsuleOpensTheListAndARowOpensInPlace() {
        let now = Date()
        server.chat.items = [RemoteChatItem(id: "m-1", kind: "user", date: now, text: "start the tests and a dev server")]
        server.chat.state = "done"
        server.chat.background = [
            RemoteBackgroundItem(id: "agent-1", kind: "agent", title: "Draft Langfuse prompts RFC", now: "Ran `gh pr view 5990`", steps: 18,
                                 startedAt: now.addingTimeInterval(-372), stopHint: "Can't stop an agent yet", lines: ["Read docs/prompts/README.md", "Ran `gh pr view 5990`"]),
            RemoteBackgroundItem(id: "sh-1", kind: "shell", title: "npm run dev", now: "ready on :3000", startedAt: now.addingTimeInterval(-90), outputFile: "/tmp/dev.out",
                                 canStop: true, lines: ["starting", "ready on :3000"]),
            RemoteBackgroundItem(id: "job:job-1", kind: "job", title: "Run screen review", state: "waiting", startedAt: now.addingTimeInterval(-260),
                                 waitingFor: "Allow ironpet tasks update 412?"),
            RemoteBackgroundItem(id: "sh-2", kind: "shell", title: "Run ChatSession tests", state: "done", startedAt: now.addingTimeInterval(-500), endedAt: now.addingTimeInterval(-300),
                                 result: "Executed 48 tests, with 0 failures"),
        ]
        app.launchArguments = ["--reset-credentials"]
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        let capsule = app.buttons["background-capsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 20))
        XCTAssertTrue(capsule.label.contains("waiting for approval"), capsule.label)
        attach("background-1-capsule")
        capsule.tap()
        let row = app.buttons["background-row-sh-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["background-row-agent-1"].exists)
        attach("background-2-sheet")
        row.tap()
        XCTAssertTrue(app.staticTexts["ready on :3000"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop"].exists)
        attach("background-3-row-open")
    }
}
