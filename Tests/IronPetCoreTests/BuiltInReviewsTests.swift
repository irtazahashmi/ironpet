import XCTest
@testable import IronPetCore

/// The screen review and the mail and calendar checks: built-ins that ship off, read their prompts from the editable store.
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

    func testBothAreBuiltInsThatStartOff() {
        for automation in [AutomationDefaults.screenReview(), AutomationDefaults.mailCalendar()] {
            XCTAssertFalse(automation.enabled, automation.id)
            XCTAssertTrue(AutomationDefaults.builtIns.contains { $0.id == automation.id }, automation.id)
            XCTAssertEqual(AutomationValidator.validate(automation), [], automation.id)
        }
    }

    func testBothRunEveryHourInTheirOwnSessionAndReportToTheChat() {
        for automation in [AutomationDefaults.screenReview(), AutomationDefaults.mailCalendar()] {
            XCTAssertEqual(automation.trigger.type, "interval", automation.id)
            XCTAssertEqual(automation.trigger.minutes, 60, automation.id)
            XCTAssertEqual(automation.action.effectiveSession, "own", automation.id)
            XCTAssertEqual(automation.action.effectiveReport, "chat", automation.id)
        }
    }

    @MainActor
    func testEachPromptIsTheEditableFileAndAnEditAppliesToTheNextRun() {
        let cases: [(Automation, String)] = [
            (AutomationDefaults.screenReview(), "screen-review"),
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

    func testEachPromptHasANoticeForAnEmptyOrNothingReply() {
        for automation in [AutomationDefaults.screenReview(), AutomationDefaults.mailCalendar()] {
            XCTAssertEqual(automation.action.quietReplies, ["NOTHING", "NOTHING_NEW"], automation.id)
        }
    }
}
