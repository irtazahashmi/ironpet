import IronPetKit
import UIKit
import Vision
import XCTest

/// The chat text size setting, and the composer scrolling to the end of a long draft, against the mock server.
final class ChatTextSizeUITests: XCTestCase {
    var server: MockIronPetServer!
    var app: XCUIApplication!
    var dark = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIronPetServer()
        try server.start()
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Allow Paste") { alert in
            for label in ["Allow Paste", "Allow"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
    }

    override func tearDown() {
        UIPasteboard.general.items = []
        server.stop()
    }

    private var input: XCUIElement { app.textViews["chat-input"] }

    private func pair(reset: Bool = true) {
        app.launchArguments = (reset ? ["--reset-credentials"] : []) + (dark ? ["--force-dark"] : [])
        app.launch()
        if reset {
            app.enterPairingLink(server.pairingLink)
            app.buttons["pair-button"].tap()
        }
    }

    private func openChat() {
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 20))
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func messageWidth() -> CGFloat {
        let text = app.staticTexts["Sizing message"]
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        // Wait until two reads half a second apart agree, so a row that is still resizing is not measured.
        var height = text.frame.width
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.5)
            let next = text.frame.width
            if next == height { break }
            height = next
        }
        return height
    }

    private func chooseSize(_ label: String) {
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        // The More tab keeps Settings open after the first visit.
        let settings = app.buttons["more-settings"]
        if !app.buttons["chat-text-size"].waitForExistence(timeout: 3) {
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tap()
        }
        let picker = app.buttons["chat-text-size"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        picker.tap()
        app.buttons[label].firstMatch.tap()
        XCTAssertTrue(app.buttons["chat-text-size"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chat-text-size"].label.hasSuffix(label), "picked \(label), shows \(app.buttons["chat-text-size"].label)")
    }

    private func seed() {
        server.chat.items = [RemoteChatItem(id: "u", kind: "user", date: Date(), text: "Sizing message"),
                             RemoteChatItem(id: "a", kind: "assistant", date: Date(), text: "An answer with `code` and a list.\n\n- one\n- two")]
    }

    // S1 and S2
    func testTheSizeSettingChangesTheMessagesAndSurvivesRelaunch() {
        seed()
        pair()
        // Defaults outlive a test run on the simulator, so start from the default explicitly.
        chooseSize("Default")
        openChat()
        let standard = messageWidth()
        attach("chat-default")
        chooseSize("Small")
        openChat()
        let small = messageWidth()
        XCTAssertLessThan(small, standard, "the default is bigger than the old size")
        chooseSize("Extra large")
        openChat()
        let extra = messageWidth()
        attach("chat-extra-large")
        XCTAssertGreaterThan(extra, standard)
        app.terminate()
        pair(reset: false)
        openChat()
        XCTAssertEqual(messageWidth(), extra, accuracy: 0.5, "the choice survives a relaunch")
    }

    // S3
    func testALongDraftScrollsToTheLastLineWhileTyping() {
        seed()
        pair()
        openChat()
        input.tap()
        for n in 1...30 { input.typeText("line \(n)\n") }
        input.typeText("the end")
        let value = input.value as? String ?? ""
        XCTAssertTrue(value.hasSuffix("the end"))
        XCTAssertTrue(input.isHittable)
        attach("long-draft-end")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        // The caret line sits above the keyboard, so the field's frame ends above it.
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY + 1)
    }

    // S4, paste and rotation. Dictation needs a real device.
    func testAPastedLongTextCanBeScrolledToItsEndAfterRotation() {
        seed()
        pair()
        openChat()
        UIPasteboard.general.string = (1...60).map { "pasted line \($0)" }.joined(separator: "\n") + "\nfinal line"
        input.tap()
        input.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 5) { paste.tap() }
        XCTAssertTrue((input.value as? String ?? "").hasSuffix("final line"))
        attach("pasted-end")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        XCTAssertTrue(input.exists)
        attach("pasted-end-landscape")
        input.swipeUp()
        XCTAssertTrue(input.isHittable)
        XCUIDevice.shared.orientation = .portrait
    }

    // Reported on a TestFlight build: five wrapped lines, with the keyboard up the fifth was cut off.
    func testFiveWrappedLinesAreAllVisibleWithTheKeyboardUpAndDown() {
        seed()
        // Enough rows that the transcript scrolls, so a drag on it can dismiss the keyboard.
        server.chat.items += (1...25).map { RemoteChatItem(id: "filler-\($0)", kind: "assistant", date: Date(), text: "Filler reply \($0)") }
        pair()
        openChat()
        input.tap()
        input.typeText("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three twenty-four twenty-five twenty-six twenty-seven twenty-eight twenty-nine thirty thirty-one thirty-two thirty-three the end of text")
        attach("five-lines-keyboard-up")
        let send = app.buttons["send-button"]
        XCTAssertTrue(send.exists)
        let upHeight = input.frame.height
        // Five lines of body text plus the insets, so no wrapped line is cut off.
        let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
        XCTAssertGreaterThan(upHeight, line * 4.5, "the field grew to its five-line height")
        XCTAssertTrue((input.value as? String ?? "").hasSuffix("the end of text"))
        // The text view ends before the send button, so no text runs under it.
        XCTAssertLessThanOrEqual(input.frame.maxX, send.frame.minX + 1)
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        // Dismiss the keyboard: the field keeps its height and the draft stays.
        // Dragging a scrollable transcript down dismisses the keyboard interactively and keeps the draft.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard went down")
        attach("five-lines-keyboard-down")
        XCTAssertEqual(input.frame.height, upHeight, accuracy: 1, "the field keeps its five-line height with the keyboard down")
        XCTAssertLessThanOrEqual(input.frame.maxX, send.frame.minX + 1)
    }

    // A draft of exactly five wrapped lines, as reported: all five show and the field does not need to scroll.
    func testADraftOfExactlyFiveLinesShowsAllFive() {
        seed()
        pair()
        openChat()
        input.tap()
        input.typeText("a1\na2\na3\na4\na5")
        attach("exactly-five-lines")
        XCTAssertEqual(input.value as? String, "a1\na2\na3\na4\na5")
        XCTAssertGreaterThan(input.frame.height, 100)
        XCTAssertTrue(input.isHittable)
    }

    // S1 in dark mode.
    func testDarkModeChatAtDefaultSize() {
        dark = true
        seed()
        pair()
        chooseSize("Default")
        openChat()
        _ = messageWidth()
        attach("chat-default-dark")
    }

    /// The words the field shows right now, read from its pixels, so the test sees what the user sees.
    private func visibleText() -> String {
        guard let image = input.screenshot().image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    // Reported on a real iPhone: the line just past the field's maximum height broke but did not scroll into view.
    func testTheLineJustPastTheMaximumHeightScrollsIntoView() {
        seed()
        pair()
        openChat()
        input.tap()
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        for (index, word) in words.enumerated() {
            input.typeText(index == 0 ? word : "\n" + word)
            let shown = visibleText()
            XCTAssertTrue(shown.localizedCaseInsensitiveContains(word), "after line \(index + 1) the field shows \(word), but shows: \(shown)")
            if index == 4 || index == 5 { attach("line-\(index + 1)") }
        }
    }
}
