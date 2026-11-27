import IronPetKit
import XCTest

/// A long chat opens on its newest 50 messages, and the page before them loads when the reader scrolls to the top.
final class ChatPagingUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    private func pair() {
        app.launchArguments = ["--reset-credentials"]
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
    }

    private func openChat() {
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.appears(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].appears(timeout: 20))
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testALongChatOpensOnItsNewestPageAndLoadsTheOlderPageAtTheTop() {
        server.chat.items = (1...300).map { RemoteChatItem(id: "p-\($0)", kind: $0 % 2 == 0 ? "assistant" : "user", date: Date(), text: "Message \($0) of a long chat") }
        server.chat.state = "done"
        pair()
        openChat()
        XCTAssertTrue(any("bubble-p-300").appears(timeout: 20), "the newest message is on screen")
        XCTAssertFalse(any("bubble-p-200").exists, "only the newest page is read at launch")
        XCTAssertTrue(server.requests.contains { $0.path == "/v1/chat/current" && $0.query.contains("limit=50") }, "the first read asks for the newest page")
        attach("paging-newest")

        // Scrolling up reaches the top of the loaded page, then the page before it loads.
        let older = any("bubble-p-201")
        var swipes = 0
        while !older.exists, swipes < 40 {
            app.descendants(matching: .any)["transcript"].firstMatch.swipeDown(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(older.appears(timeout: 10), "the page above the newest one loads when the top shows")
        XCTAssertTrue(server.requests.contains { $0.query.contains("before=p-251") }, "the phone asked for the page before its oldest message")
        attach("paging-older-loaded")
    }
}
