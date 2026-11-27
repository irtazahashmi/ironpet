import IronPetKit
import XCTest

/// A form with several questions shows one question at a time, with Back, Next and a page label. The card keeps its height from page to page.
final class ChatFormPagesUITests: XCTestCase {
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

    private func question(_ n: Int, required: Bool = true) -> [RemoteFormField] {
        [RemoteFormField(id: "question_\(n)", title: "Which pasta shape for dish \(n + 1)?", detail: n == 1 ? "Pick the one the guests asked for, and say why if none fits." : "", required: required, type: "single",
                         options: [RemoteFormOption(value: "penne", title: "Penne"), RemoteFormOption(value: "fusilli", title: "Fusilli")]),
         RemoteFormField(id: "question_\(n)_custom", title: "Other", type: "text")]
    }

    private func openChat(questions: Int, extraArguments: [String] = []) {
        server.chat.items = [RemoteChatItem(id: "m-1", kind: "user", date: Date(), text: "plan the dinner")]
        server.chat.state = "running"
        server.chat.forms = [RemoteForm(id: "form-1", message: "A few dinner questions", fields: (0..<questions).flatMap { question($0) })]
        app.launchArguments = ["--reset-credentials"] + extraArguments
        app.launch()
        app.enterPairingLink(server.pairingLink)
        app.buttons["pair-button"].tap()
        let tab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.textViews["chat-input"].waitForExistence(timeout: 20))
    }

    private var label: XCUIElement { app.staticTexts["page-form-1"] }
    private var back: XCUIElement { app.buttons["back-form-1"] }
    private var next: XCUIElement { app.buttons["next-form-1"] }
    private var submit: XCUIElement { app.buttons["submit-form-1"] }

    func testThreeQuestionsPageWithBackAndNext() {
        openChat(questions: 3)
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertEqual(label.label, "1 of 3")
        XCTAssertTrue(app.buttons["option-question_0-penne"].exists)
        XCTAssertFalse(app.buttons["option-question_1-penne"].exists, "only the first question shows")
        XCTAssertFalse(back.isEnabled)
        XCTAssertTrue(next.isEnabled)
        XCTAssertFalse(submit.exists, "Submit waits for the last page")
        attach("page-1")

        app.buttons["option-question_0-fusilli"].tap()
        next.tap()
        XCTAssertEqual(label.label, "2 of 3")
        XCTAssertTrue(app.buttons["option-question_1-penne"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["option-question_0-penne"].exists)
        XCTAssertTrue(back.isEnabled)

        back.tap()
        XCTAssertEqual(label.label, "1 of 3")
        let kept = app.buttons["option-question_0-fusilli"]
        XCTAssertTrue(kept.waitForExistence(timeout: 5))
        XCTAssertEqual(server.chat.forms.first?.answers["question_0"], .text("fusilli"), "the first answer is still held after going back")

        next.tap(); next.tap()
        XCTAssertEqual(label.label, "3 of 3")
        XCTAssertFalse(next.exists)
        XCTAssertTrue(submit.exists)
        attach("page-3")
    }

    func testOneQuestionHasNoPagingControls() {
        openChat(questions: 1)
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertFalse(label.exists)
        XCTAssertFalse(back.exists)
        XCTAssertFalse(next.exists)
        XCTAssertTrue(app.buttons["option-question_0-penne"].exists)
    }

    func testSubmitJumpsToTheFirstUnansweredQuestion() {
        openChat(questions: 3)
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        app.buttons["option-question_0-penne"].tap()
        // Submit reads the answers the phone holds, so wait until the mock has the first one and the phone has reloaded it.
        let deadline = Date().addingTimeInterval(10)
        while server.chat.forms.first?.answers["question_0"] == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertNotNil(server.chat.forms.first?.answers["question_0"])
        Thread.sleep(forTimeInterval: 0.5)
        next.tap(); next.tap()
        XCTAssertEqual(label.label, "3 of 3")
        submit.tap()
        XCTAssertTrue(app.staticTexts["page-form-1"].waitForExistence(timeout: 5))
        XCTAssertEqual(label.label, "2 of 3", "question 2 is the first one without an answer")
        XCTAssertTrue(app.buttons["option-question_1-penne"].exists)
    }

    /// On the last page the Submit button holds one line of text, so it is as tall as Back and the row does not grow.
    func testSubmitOnTheLastPageIsOneLineAndAsTallAsBack() {
        openChat(questions: 2)
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        XCTAssertEqual(label.label, "2 of 2")
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertEqual(submit.frame.height, back.frame.height, accuracy: 6, "Submit is not taller than Back, so its label is on one line")
        attach("submit-last-page")
    }

    /// At the largest accessibility text size the controls stack and Submit still holds a single line.
    func testSubmitStaysOneLineAtTheLargestTextSize() {
        openChat(questions: 2, extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        XCTAssertEqual(label.label, "2 of 2")
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        // Measured on iPhone 17: Back is 58 pt and a one-line Submit 77 pt, so a wrapped two-line label (about 125 pt) fails this.
        XCTAssertLessThan(submit.frame.height, 1.5 * back.frame.height, "Submit is a single line")
        XCTAssertGreaterThan(submit.frame.minY, back.frame.maxY - 1, "the controls stack, with Submit below Back")
        attach("submit-largest-text")
    }

    func testChangingPageDoesNotMoveTheComposer() {
        openChat(questions: 3)
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let composer = app.textViews["chat-input"]
        let before = composer.frame
        let message = app.staticTexts["A few dinner questions"].frame
        next.tap()
        XCTAssertEqual(label.label, "2 of 3")
        XCTAssertEqual(composer.frame, before, "the composer stays where it was")
        XCTAssertEqual(app.staticTexts["A few dinner questions"].frame, message, "the card header stays where it was")
        next.tap()
        XCTAssertEqual(label.label, "3 of 3")
        XCTAssertEqual(composer.frame, before)
        XCTAssertEqual(app.staticTexts["A few dinner questions"].frame, message, "the card header stays put on the last page too")
    }
}
