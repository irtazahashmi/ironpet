import IronPetKit
import XCTest

/// A reply that streams on the Mac grows on the phone in many steps, not once at the end.
final class ChatStreamingUITests: XCTestCase {
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
        app.launchArguments = ["--reset-credentials"]
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].waitForExistence(timeout: 20))
    }

    /// Streams 30 words over 3 s and returns the distinct texts the bubble showed, sampled while it streams.
    private func streamedTexts() -> (seen: [String], final: String) {
        var seen: [String] = []
        var full = ""
        let bubble = app.staticTexts.matching(identifier: "bubble-reply").firstMatch
        for n in 1...30 {
            let word = "w\(n) "
            full += word
            server.streamChunk(item: "reply", word)
            Thread.sleep(forTimeInterval: 0.1)
            if bubble.exists, !bubble.label.isEmpty, seen.last != bubble.label { seen.append(bubble.label) }
        }
        return (seen, full.trimmingCharacters(in: .whitespaces))
    }

    // S1
    func testAStreamedReplyGrowsInManySteps() {
        server.chat.items = [RemoteChatItem(id: "m-1", kind: "user", date: Date(), text: "Tell me a story")]
        openChat()
        let result = streamedTexts()
        server.finishTurn()
        XCTAssertGreaterThanOrEqual(result.seen.count, 10, "intermediate texts: \(result.seen.count)")
        XCTAssertEqual(server.messageReads, 0, "the events carried the text")
        let bubble = app.staticTexts.matching(identifier: "bubble-reply").firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        XCTAssertEqual(bubble.label.trimmingCharacters(in: .whitespaces), result.final)
    }
}
