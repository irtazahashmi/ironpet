import XCTest
@testable import IronPetCore

/// The mail and calendar checks of earlier builds: no longer added, but a kept copy still reads its prompt from the editable store.
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

    func testTheShippedCopyIsValidAndOff() {
        for automation in [RetiredBuiltIns.mailCalendar()] {
            XCTAssertFalse(automation.enabled, automation.id)
            XCTAssertEqual(AutomationValidator.validate(automation), [], automation.id)
        }
    }

    func testItRunsEveryHourInItsOwnSessionAndReportsToTheChat() {
        for automation in [RetiredBuiltIns.mailCalendar()] {
            XCTAssertEqual(automation.trigger.type, "interval", automation.id)
            XCTAssertEqual(automation.trigger.minutes, 60, automation.id)
            XCTAssertEqual(automation.action.effectiveSession, "own", automation.id)
            XCTAssertEqual(automation.action.effectiveReport, "chat", automation.id)
        }
    }

    @MainActor
    func testThePromptIsTheEditableFileAndAnEditAppliesToTheNextRun() {
        let cases: [(Automation, String)] = [
            (RetiredBuiltIns.mailCalendar(), "mail-calendar"),
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
        for automation in [RetiredBuiltIns.mailCalendar()] {
            XCTAssertEqual(automation.action.quietReplies, ["NOTHING", "NOTHING_NEW"], automation.id)
        }
    }
}

extension BuiltInReviewsTests {
    func testScreenReviewIsNoLongerAPrompt() {
        XCTAssertNil(Prompts.info("screen-review"))
        XCTAssertNil(Prompts.defaultText("screen-review"))
        for id in ["task-scan", "task-review", "task-instructions"] { XCTAssertNil(Prompts.info(id), id) }
    }
}
