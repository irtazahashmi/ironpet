import IronPetKit
import UIKit
import XCTest

/// Pasting images into the chat, the composer's look, and the Mac's chat background, against the mock server.
final class PasteUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!
    /// Launch in dark mode. Set before `pair()`.
    var dark = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
        // The system asks before an app reads a clipboard another app wrote. Allow it if it shows.
        addUIInterruptionMonitor(withDescription: "Allow Paste") { alert in
            for label in ["Allow Paste", "Allow"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
    }

    override func tearDown() {
        UIPasteboard.general.items = []
        server.stop()
    }

    private func pair() {
        app.launchArguments = ["--reset-credentials"] + (dark ? ["--force-dark"] : [])
        app.launch()
        let field = app.textFields["pairing-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server.pairingLink)
        app.buttons["pair-button"].tap()
    }

    private func openChat() {
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 20))
    }

    private var input: XCUIElement { app.textViews["chat-input"] }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Waits until the app's screenshot is as bright or as dark as the launch appearance needs, so a shot is never taken
    /// mid-transition and an appearance that did not apply fails the test. The app is launched in dark mode with `--force-dark`,
    /// because `XCUIDevice.appearance` and the system launch arguments have no effect on every simulator.
    private func assertAppearance(file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(10)
        var level = Self.brightness(app.screenshot().image)
        while Date() < end, dark ? level > 0.45 : level < 0.55 {
            Thread.sleep(forTimeInterval: 0.5)
            level = Self.brightness(app.screenshot().image)
        }
        XCTAssertTrue(dark ? level <= 0.45 : level >= 0.55, "the \(dark ? "dark" : "light") appearance did not show (brightness \(level))", file: file, line: line)
    }

    /// Mean brightness of a picture, 0 for black to 1 for white, from a 16 by 16 copy.
    private static func brightness(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0.5 }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) { total += (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 3 / 255 }
        return total / Double(side * side)
    }

    private func copyImage(width: Int = 600, height: Int = 400) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        UIPasteboard.general.image = renderer.image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 40, y: 40, width: width / 2, height: height / 2))
        }
    }

    /// Long-press the field and tap Paste in the menu that follows.
    private func pasteFromMenu() {
        input.tap()
        input.press(forDuration: 1.2)
        let candidates = [app.menuItems["Paste"], app.buttons["Paste"]]
        let paste = candidates.first { $0.waitForExistence(timeout: 3) } ?? candidates[0]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the Paste menu item shows when the clipboard holds an image")
        paste.tap()
        // The permission alert is not in the app's hierarchy, so a tap on the app lets the monitor see it.
        app.tap()
    }

    // S1
    func testLongPressPasteAddsAThumbnailAndKeepsTheDraft() {
        pair()
        openChat()
        input.tap()
        input.typeText("keep me")
        copyImage()
        pasteFromMenu()
        XCTAssertTrue(any("attachment-thumbnail-0").waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "keep me")
        attach("pasted-thumbnail")
    }

    // S2
    func testKeyboardPasteAddsTheSameThumbnail() {
        pair()
        openChat()
        input.tap()
        copyImage()
        input.typeKey("v", modifierFlags: .command)
        app.tap()
        XCTAssertTrue(any("attachment-thumbnail-0").waitForExistence(timeout: 10))
    }

    // S3
    func testPastedTextGoesIntoTheFieldAndAddsNoAttachment() {
        pair()
        openChat()
        UIPasteboard.general.string = "from the clipboard"
        pasteFromMenu()
        let pasted = NSPredicate { _, _ in (self.input.value as? String) == "from the clipboard" }
        wait(for: [XCTNSPredicateExpectation(predicate: pasted, object: nil)], timeout: 10)
        XCTAssertFalse(any("attachment-thumbnail-0").exists)
    }

    // S4
    func testRemovingAThumbnailUploadsNothing() {
        pair()
        openChat()
        copyImage()
        pasteFromMenu()
        XCTAssertTrue(any("attachment-thumbnail-0").waitForExistence(timeout: 10))
        app.buttons["attachment-remove-0"].tap()
        XCTAssertTrue(any("attachment-thumbnail-0").waitForNonExistence(timeout: 5))
        input.tap()
        input.typeText("only text")
        app.buttons["send-button"].tap()
        let sent = NSPredicate { _, _ in self.server.requests.contains { $0.path == "/v1/chat/current/messages" } }
        wait(for: [XCTNSPredicateExpectation(predicate: sent, object: nil)], timeout: 10)
        XCTAssertEqual(server.count("POST /v1/uploads"), 0)
    }

    // S6, S12
    func testSendingAPastedImageUploadsItAndTheTranscriptShowsIt() {
        pair()
        openChat()
        copyImage()
        pasteFromMenu()
        XCTAssertTrue(any("attachment-thumbnail-0").waitForExistence(timeout: 10))
        input.tap()
        input.typeText("what is this")
        app.buttons["send-button"].tap()
        XCTAssertTrue(any("attachment-thumbnail-0").waitForNonExistence(timeout: 10), "the thumbnail leaves the composer on send")
        let sent = NSPredicate { _, _ in self.server.requests.contains { $0.path == "/v1/chat/current/messages" && ($0.json["upload_ids"] as? [String])?.count == 1 } }
        wait(for: [XCTNSPredicateExpectation(predicate: sent, object: nil)], timeout: 10)
        let upload = server.requests.first { $0.path == "/v1/uploads" }
        XCTAssertEqual(upload?.headers["content-type"], "image/jpeg")
        XCTAssertTrue(((upload?.headers["x-file-name"] ?? "").removingPercentEncoding ?? "").hasSuffix(".jpg"))
        let photo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "the transcript shows the image")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chip-'")).firstMatch.exists)
        attach("sent-image")
    }

    // Step 4 of #190: a Mac screenshot in the chat is a thumbnail on the phone, and a tap opens it full size.
    func testAMacScreenshotShowsAsAThumbnailAndOpensFullSize() {
        let name = "ab12cd34-Screen Shot.png"
        let size = CGSize(width: 1200, height: 800)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        server.setChatImage(UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }, for: "shot-1")
        var snapshot = server.chat
        snapshot.items.append(RemoteChatItem(id: "shot-1", kind: "screenshot", fileName: name, isImage: true))
        server.chat = snapshot
        pair()
        openChat()
        let photo = any("photo-\(name)")
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "the Mac's screenshot shows as a thumbnail")
        XCTAssertFalse(any("chip-\(name)").exists, "the chip is gone")
        attach("mac-screenshot-thumbnail")
        photo.tap()
        XCTAssertTrue(any("image-viewer-picture").waitForExistence(timeout: 10), "a tap opens the full image")
        attach("mac-screenshot-full")
        app.buttons["image-viewer-done"].firstMatch.tap()
        XCTAssertTrue(any("image-viewer-picture").waitForNonExistence(timeout: 10))
        XCTAssertEqual(server.count("GET /v1/chat/messages/shot-1/file"), 1, "one download serves the thumbnail and the full picture")
    }

    func testAMacScreenshotTheMacNoLongerHasKeepsTheChipAndSaysWhy() {
        let name = "ab12cd34-Gone.png"
        var snapshot = server.chat
        snapshot.items.append(RemoteChatItem(id: "shot-gone", kind: "screenshot", fileName: name, isImage: true))
        server.chat = snapshot
        pair()
        openChat()
        let chip = any("chip-\(name)")
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["the file is no longer on the Mac"].waitForExistence(timeout: 10))
    }

    // S9, S13
    func testComposerStatesInLight() { composerStates() }
    func testComposerStatesInDark() { dark = true; composerStates() }

    private func composerStates() {
        let name = dark ? "dark" : "light"
        pair()
        openChat()
        assertAppearance()
        XCTAssertTrue(any("attach-button").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["send-button"].exists, "send is hidden on an empty draft")
        XCTAssertFalse(app.buttons["stop-button"].exists)
        attach("composer-empty-\(name)")
        input.tap()
        input.typeText("a draft")
        XCTAssertTrue(app.buttons["send-button"].waitForExistence(timeout: 5))
        copyImage()
        pasteFromMenu()
        XCTAssertTrue(any("attachment-thumbnail-0").waitForExistence(timeout: 10))
        attach("composer-draft-thumbnail-\(name)")
        // A turn the Mac started shows the red Stop circle, and it goes when the turn ends.
        var snapshot = server.chat
        snapshot.running = true
        snapshot.state = "running"
        server.chat = snapshot
        server.publish(RemoteEvent.chatState)
        let stop = app.buttons["stop-button"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        attach("composer-running-\(name)")
        stop.tap()
        let stopped = NSPredicate { _, _ in self.server.requests.contains { $0.line == "POST /v1/chat/current/stop" } }
        wait(for: [XCTNSPredicateExpectation(predicate: stopped, object: nil)], timeout: 10)
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10))
    }

    // S8
    func testTheChatDrawsTheMacBackgroundInLight() { chatBackground() }
    func testTheChatDrawsTheMacBackgroundInDark() { dark = true; chatBackground() }

    private func chatBackground() {
        server.pet = RemotePet(name: "Ghost", mood: "idle", badge: 0, tricks: [], background: "paws")
        pair()
        openChat()
        XCTAssertTrue(any("chat-background-paws").waitForExistence(timeout: 20), "the chat follows the pet resource's background")
        assertAppearance()
        attach("background-paws-\(dark ? "dark" : "light")")
    }
}
