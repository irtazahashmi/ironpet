import XCTest
@testable import IronPetCore

/// The mail and calendar checks: a built-in that ships off and reads its prompt from the editable store.
final class BuiltInReviewsTests: XCTestCase {
    private var directory: URL!
    private var savedDirectory: URL!

    override func setUp() {
        super.setUp()
        savedDirectory = PromptStore.directory
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("builtin-reviews-\(UUID().uuidString)")
        PromptStore.directory = directory
        PromptStore.defaultText = { Prompts.defaultText($0) }
    }

    override func tearDown() {
        PromptStore.directory = savedDirectory
        PromptStore.defaultText = { Prompts.defaultText($0) }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testItIsABuiltInThatStartsOff() {
        for automation in [AutomationDefaults.mailCalendar()] {
            XCTAssertFalse(automation.enabled, automation.id)
            XCTAssertTrue(AutomationDefaults.builtIns.contains { $0.id == automation.id }, automation.id)
            XCTAssertEqual(AutomationValidator.validate(automation), [], automation.id)
        }
    }

    func testItRunsEveryHourInItsOwnSessionAndReportsToTheChat() {
        for automation in [AutomationDefaults.mailCalendar()] {
            XCTAssertEqual(automation.trigger.type, "interval", automation.id)
            XCTAssertEqual(automation.trigger.minutes, 60, automation.id)
            XCTAssertEqual(automation.action.effectiveSession, "own", automation.id)
            XCTAssertEqual(automation.action.effectiveReport, "chat", automation.id)
        }
    }

    @MainActor
    func testThePromptIsTheEditableFileAndAnEditAppliesToTheNextRun() {
        let cases: [(Automation, String)] = [
            (AutomationDefaults.mailCalendar(), "mail-calendar"),
        ]
        for (automation, id) in cases {
            let prompt = automation.action.prompt ?? ""
            XCTAssertFalse(AutomationService.usesItemData(prompt), id)
            let shipped = Prompts.text(id)
            XCTAssertFalse(shipped.isEmpty, id)
            XCTAssertEqual(AutomationTemplate.render(prompt, values: [:]), shipped, id)
            PromptStore.save(id, text: "Edited \(id).")
            XCTAssertEqual(AutomationTemplate.render(prompt, values: [:]), "Edited \(id).", id)
        }
    }

    func testThePromptHasANoticeForAnEmptyOrNothingReply() {
        for automation in [AutomationDefaults.mailCalendar()] {
            XCTAssertEqual(automation.action.quietReplies, ["NOTHING", "NOTHING_NEW"], automation.id)
        }
    }
}

extension BuiltInReviewsTests {
    func testScreenReviewIsNoLongerABuiltInOrAPrompt() {
        XCTAssertFalse(AutomationDefaults.builtIns.contains { $0.id == "screen-review" })
        XCTAssertNil(Prompts.info("screen-review"))
        XCTAssertNil(Prompts.defaultText("screen-review"))
        for id in ["task-scan", "task-review", "task-instructions"] { XCTAssertNil(Prompts.info(id), id) }
    }
}
