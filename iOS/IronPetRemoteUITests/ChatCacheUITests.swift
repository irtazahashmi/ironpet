import IronPetKit
import XCTest

/// The chat the phone saw last shows at launch, even when the Mac cannot be reached.
final class ChatCacheUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    private func openChat() {
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.appears(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].appears(timeout: 20))
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testTheChatSavedLastTimeShowsAfterARelaunchWithTheMacOffline() {
        server.chat.items = (1...3).map { RemoteChatItem(id: "k-\($0)", kind: "user", date: Date(), origin: "ios", text: "Kept message \($0)") }
        server.chat.state = "done"

        app.launchArguments = ["--reset-credentials"]
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        openChat()
        XCTAssertTrue(any("bubble-k-3").appears(timeout: 20), "the chat loads from the Mac once")

        // The phone is closed and the Mac goes away. The app opens on the chat it saved.
        app.terminate()
        server.stop()
        app.launchArguments = []
        app.launch()
        openChat()
        XCTAssertTrue(any("bubble-k-3").appears(timeout: 10), "the saved chat shows with the Mac offline")
        XCTAssertTrue(app.staticTexts["Kept message 1"].exists)
    }
}
