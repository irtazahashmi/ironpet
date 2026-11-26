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
        let store = AutomationStore(paths: paths, defaults: { [] }, watch: false)
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
        let store = AutomationStore(paths: paths, defaults: { [] }, watch: false)
        XCTAssertTrue(store.automations.isEmpty)
        XCTAssertNil(store.error)
    }

    func testNoShippedCopyOrPromptNamesTheTaskList() {
        let words = ["tasks_", "task_filters", "task list", "task board", "weekly review", "task review", "task scan", "ironpet-tasks", "next action"]
        for automation in RetiredBuiltIns.shipped {
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

/// Scenarios S1 to S4 of "No built-in automations": ironpet adds nothing, drops the untouched copies of what earlier builds
/// added, keeps the ones the user turned on or edited, and never brings a deleted one back.
@MainActor
final class NoBuiltInAutomationsTests: AutomationTestCase {
    private func write(_ list: [Automation]) throws {
        let data = try JSONEncoder().encode(["automations": list])
        try data.write(to: paths.file)
    }

    private func start() -> AutomationStore {
        AutomationStore(paths: paths, defaults: { XCTFail("an existing file is not seeded"); return [] }, watch: false)
    }

    // S1
    func testAFreshInstallHasNoAutomations() {
        let store = AutomationStore(paths: paths, defaults: { [] }, watch: false)
        XCTAssertEqual(store.automations, [])
    }

    // S2
    func testUntouchedSwitchedOffCopiesAreRemovedAndTheFileIsRewritten() throws {
        let mine = Automation(id: "my-check", name: "Mine", trigger: .init(type: "interval", minutes: 30, clock: "wall"),
                              action: .init(type: "bubble", title: "hi"), createdBy: "user")
        try write(RetiredBuiltIns.shipped + [mine])
        let store = start()
        XCTAssertEqual(store.automations.map(\.id), ["my-check"])
        let saved = try String(contentsOf: paths.file, encoding: .utf8)
        for id in ["morning-brief", "day-recap", "mail-calendar", "github-alerts", "sentry-alerts"] {
            XCTAssertFalse(saved.contains("\"\(id)\""), "\(id) is gone from the file")
        }
    }

    // S3
    func testACopyTheUserEnabledOrEditedStaysWithItsContent() throws {
        var enabled = RetiredBuiltIns.morningBrief(enabled: true)
        enabled.enabled = true
        var edited = RetiredBuiltIns.dayRecap()
        edited.trigger.times = ["17:00"]
        var prompt = RetiredBuiltIns.mailCalendar()
        prompt.action.prompt = "Check my mail for invoices."
        var github = AutomationDefaults.github(enabled: false)
        github.trigger.minutes = 10
        try write([enabled, edited, prompt, github, AutomationDefaults.sentry(enabled: true)])
        let store = start()
        XCTAssertEqual(store.automations, [enabled, edited, prompt, github, AutomationDefaults.sentry(enabled: true)])
        let again = start()
        XCTAssertEqual(again.automations.count, 5, "a second launch changes nothing")
    }

    // S4
    func testADeletedFormerBuiltInDoesNotComeBack() throws {
        let kept = RetiredBuiltIns.morningBrief(enabled: true)
        try write([kept])
        let store = start()
        try store.replace([])
        XCTAssertEqual(start().automations, [])
    }
}
