import XCTest
@testable import IronPet
@testable import IronPetCore

/// S5: the built-ins name no tasks, and an upgrade removes the automations that worked on the task list without an error.
@MainActor
final class InboxRetirementTests: AutomationTestCase {
    private func write(_ json: String) throws {
        try json.write(to: paths.file, atomically: true, encoding: .utf8)
    }

    private let oldFile = """
    {"automations":[
      {"id":"task-review","name":"Task review","enabled":true,"trigger":{"type":"interval","minutes":20,"clock":"wall"},"action":{"type":"prompt","prompt":"Review"},"createdBy":"user"},
      {"id":"weekly-review","name":"Weekly review","enabled":true,"trigger":{"type":"daily","times":["16:00"],"weekdays":["fri"]},"action":{"type":"digest","digest":"review"},"createdBy":"user"},
      {"id":"task-scan","name":"Task scan","enabled":true,"trigger":{"type":"interval","minutes":30,"clock":"wall"},"action":{"type":"prompt","prompt":"Scan"},"createdBy":"user"},
      {"id":"my-check","name":"Mine","enabled":true,"trigger":{"type":"interval","minutes":30,"clock":"wall"},"action":{"type":"prompt","prompt":"Check"},"createdBy":"user"},
      {"id":"morning-brief","name":"Morning brief","enabled":true,"trigger":{"type":"daily","times":["08:30"]},"action":{"type":"digest","digest":"brief"},"createdBy":"user"}
    ]}
    """

    func testAnUpgradeRemovesTheRetiredBuiltInsAndKeepsTheRest() throws {
        try write(oldFile)
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        let ids = Set(store.automations.map(\.id))
        XCTAssertFalse(ids.contains("task-review") || ids.contains("weekly-review") || ids.contains("task-scan"))
        XCTAssertTrue(ids.contains("my-check"), "the user's own automation stays")
        XCTAssertTrue(ids.contains("morning-brief"))
        XCTAssertNil(store.error, "the old file loads without an error")
        let saved = try String(contentsOf: paths.file, encoding: .utf8)
        XCTAssertFalse(saved.contains("weekly-review") || saved.contains("task-review"), "the file on disk is rewritten")
    }

    func testAReviewDigestOnAnyIdIsRemovedToo() throws {
        try write("""
        {"automations":[{"id":"my-friday","name":"Friday","enabled":true,"trigger":{"type":"daily","times":["16:00"]},"action":{"type":"digest","digest":"review"},"createdBy":"user"}]}
        """)
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: [], watch: false)
        XCTAssertTrue(store.automations.isEmpty)
        XCTAssertNil(store.error)
    }

    func testTheBuiltInsAreTheBriefTheRecapAndTheMailChecks() {
        XCTAssertEqual(AutomationDefaults.builtIns.map(\.id), [AutomationDefaults.morningBriefID, AutomationDefaults.dayRecapID, AutomationDefaults.mailCalendarID])
        XCTAssertEqual(AutomationDefaults.nodeLevelIDs, [AutomationDefaults.morningBriefID, AutomationDefaults.dayRecapID, AutomationDefaults.mailCalendarID])
    }

    func testNoBuiltInOrBuiltInPromptNamesTheTaskList() {
        let words = ["tasks_", "task_filters", "task list", "task board", "weekly review", "task review", "task scan", "ironpet-tasks", "next action"]
        for automation in AutomationDefaults.builtIns {
            let text = [automation.name, automation.action.prompt ?? "", automation.action.title ?? ""].joined(separator: "\n").lowercased()
            for word in words { XCTAssertFalse(text.contains(word), "\(automation.id) mentions \(word)") }
        }
        for prompt in BuiltInPromptsData.all {
            let name = prompt.id
            let text = prompt.text.lowercased()
            for word in words { XCTAssertFalse(text.contains(word), "prompt \(name) mentions \(word)") }
        }
        for skill in BundledSkills.all {
            let text = skill.content.lowercased()
            for word in words { XCTAssertFalse(text.contains(word), "skill \(skill.name) mentions \(word)") }
        }
    }

    func testTheRetiredPromptsAndSkillAreNotBundled() {
        for name in ["task-review", "task-scan", "task-instructions"] { XCTAssertFalse(BuiltInPromptsData.all.map(\.id).contains(name), name) }
        XCTAssertNil(BundledSkills.named("ironpet-tasks"))
    }
}
