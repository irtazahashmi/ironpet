import IronPetKit
import UIKit
import XCTest

/// The chat background shared with the Mac: drawn on the chat and the other screens, changed from the phone's settings, and a photo
/// uploaded to the Mac. All against the mock server.
final class BackgroundUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!
    /// Launch in dark mode. Set before `pair()`.
    var dark = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() { server.stop() }

    private func pair() {
        app.launchArguments = ["--reset-credentials", "--stub-photo"] + (dark ? ["--force-dark"] : [])
        app.launch()
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server.pairingLink)
        app.buttons["pair-button"].tap()
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 20))
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func openChat() {
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(app.textViews["chat-input"].waitForExistence(timeout: 20))
    }

    private func openSettings() {
        app.tabBars.buttons["More"].tap()
        let row = app.buttons["more-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.switches["reminders-paused"].waitForExistence(timeout: 20))
        reveal("background-default")
    }

    /// The picker sits below the privacy switches, and a form draws only the rows near the screen. Scrolls until the row is there.
    private func reveal(_ id: String) {
        var swipes = 0
        while !(any(id).exists && any(id).isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(any(id).exists, "\(id) is on the settings screen")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        XCTAssertEqual(result, .completed, message)
    }

    /// A different picture each run. The app keeps downloaded files by hash between runs, so a repeated picture would never be fetched.
    private static func photo(width: Int = 240 + Int.random(in: 0..<60), height: Int = 360) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        }
    }

    // S1
    func testABuiltInPickedOnTheMacShowsInTheChatWithoutReopeningIt() {
        pair()
        openChat()
        XCTAssertTrue(any("chat-background-default").waitForExistence(timeout: 20))
        server.pet = RemotePet(name: "Ghost", mood: "idle", badge: 0, tricks: [], background: "paws")
        server.publish(RemoteEvent.settingsChanged)
        XCTAssertTrue(any("chat-background-paws").waitForExistence(timeout: 10), "the push is enough, the chat stays open")
    }

    // S2
    func testACustomImageIsFetchedWithTheTokenAndDrawnInTheChat() {
        let hash = server.setBackgroundImage(Self.photo())
        pair()
        openChat()
        XCTAssertTrue(any("chat-background-custom").waitForExistence(timeout: 20))
        waitFor("the image is downloaded by its hash") { self.server.requests.contains { $0.path == "/v1/assets/\(hash)" } }
        let fetch = server.requests.first { $0.path == "/v1/assets/\(hash)" }
        XCTAssertEqual(fetch?.headers["authorization"], "Bearer \(server.token)")
        attach("custom-chat")
    }

    // S3
    func testPickingABuiltInInSettingsChangesTheMacAndTheChat() {
        pair()
        openSettings()
        reveal("background-paws")
        any("background-paws").tap()
        waitFor("the phone patches the Mac's chat.background") { self.server.config.chat.background == "paws" }
        XCTAssertTrue(any("screen-background-paws").waitForExistence(timeout: 10), "the settings screen draws it too")
        XCTAssertTrue(any("background-paws").isSelected, "the chosen background is marked selected")
        attach("settings-paws-\(dark ? "dark" : "light")")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openChat()
        XCTAssertTrue(any("chat-background-paws").waitForExistence(timeout: 10))
    }

    // S4
    func testPickingAPhotoUploadsItToTheMacAndItBecomesTheCustomBackground() {
        pair()
        openSettings()
        reveal("background-photo")
        any("background-photo").tap()
        waitFor("the photo reaches the Mac") { self.server.requests.contains { $0.line == "POST /v1/settings/background" } }
        let upload = server.requests.first { $0.line == "POST /v1/settings/background" }
        XCTAssertEqual(upload?.body.prefix(3).map { $0 }, [0xFF, 0xD8, 0xFF], "a JPEG, as the Mac accepts")
        XCTAssertLessThanOrEqual(upload?.body.count ?? .max, 20 << 20)
        XCTAssertEqual(upload?.headers["authorization"], "Bearer \(server.token)")
        XCTAssertEqual(server.config.chat.background, "custom")
        XCTAssertTrue(any("screen-background-custom").waitForExistence(timeout: 20), "the custom image is drawn once the phone has fetched it")
        XCTAssertTrue(any("background-custom").waitForExistence(timeout: 10))
        attach("settings-custom-\(dark ? "dark" : "light")")
    }

    // S5
    func testTheBackgroundShowsInLightAndDarkBehindReadableBubbles() {
        server.pet = RemotePet(name: "Ghost", mood: "idle", badge: 0, tricks: [], background: "paws")
        pair()
        openChat()
        XCTAssertTrue(any("chat-background-paws").waitForExistence(timeout: 20))
        attach("chat-paws-\(dark ? "dark" : "light")")
    }

    func testTheSettingsAndTheChatShowTheBackgroundInDark() {
        dark = true
        server.pet = RemotePet(name: "Ghost", mood: "idle", badge: 0, tricks: [], background: "paws")
        pair()
        openChat()
        XCTAssertTrue(any("chat-background-paws").waitForExistence(timeout: 20))
        attach("chat-paws-dark")
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(any("screen-background-paws").waitForExistence(timeout: 10))
        attach("more-paws-dark")
    }
}
