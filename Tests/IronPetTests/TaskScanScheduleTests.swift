import XCTest
@testable import IronPet
@testable import IronPetCore

/// The task scan runs as a system automation: the engine schedules it, but the user's list and the automation tools never show it.
@MainActor
final class TaskScanScheduleTests: AutomationTestCase {
    private var scans = 0

    private func rig(_ tasks: Config.Tasks = Config.Tasks(), stored: [Automation] = []) -> Rig {
        let rig = makeRig(stored)
        scans = 0
        rig.service.runTaskScan = { [unowned self] in
            scans += 1
            return TaskScanner.Outcome(skipped: true)
        }
        rig.service.system = AutomationDefaults.system(for: tasks)
        return rig
    }

    /// Advances the wall clock, one tick a minute.
    private func advance(_ rig: Rig, minutes: Int) {
        for _ in 0..<minutes {
            clock.now = clock.now.addingTimeInterval(60)
            rig.engine.tick()
        }
    }

    func testTheDefaultIsOnEverySixtyMinutes() async {
        let defaults = Config.Tasks()
        XCTAssertTrue(defaults.scan)
        XCTAssertEqual(defaults.scanMinutes, 60)
        let system = AutomationDefaults.system(for: defaults)
        XCTAssertEqual(system.map(\.id), [AutomationDefaults.taskScanID])
        XCTAssertEqual(system.first?.trigger.minutes, 60)
        XCTAssertEqual(system.first?.trigger.clock, "wall")
    }

    func testTheScanRunsOnItsInterval() async {
        let rig = rig()
        advance(rig, minutes: 59)
        XCTAssertEqual(scans, 0)
        advance(rig, minutes: 2)
        await until("the first scan") { self.scans == 1 }
        advance(rig, minutes: 61)
        await until("the second scan") { self.scans == 2 }
    }

    func testChangingTheIntervalRunsItAtTheNewInterval() async {
        let rig = rig()
        var tasks = Config.Tasks()
        tasks.scanMinutes = 15
        rig.service.system = AutomationDefaults.system(for: tasks)
        advance(rig, minutes: 16)
        await until("a scan after the shorter interval") { self.scans == 1 }
    }

    func testTurningTheScanOffStopsIt() async {
        let rig = rig()
        var tasks = Config.Tasks()
        tasks.scan = false
        rig.service.system = AutomationDefaults.system(for: tasks)
        XCTAssertEqual(rig.engine.automations.map(\.id).filter { $0 == AutomationDefaults.taskScanID }, [])
        advance(rig, minutes: 130)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(scans, 0)
        tasks.scan = true
        rig.service.system = AutomationDefaults.system(for: tasks)
        advance(rig, minutes: 61)
        await until("a scan after it was turned back on") { self.scans == 1 }
    }

    func testTheIntervalIsClampedToTheSettingsRange() {
        var config = Config()
        config.tasks.scanMinutes = 1
        XCTAssertEqual(config.sanitized().tasks.scanMinutes, 15)
        config.tasks.scanMinutes = 100_000
        XCTAssertEqual(config.sanitized().tasks.scanMinutes, 1_440)
    }

    func testTheAutomationsListAndTheAutomationToolsNeverShowIt() async throws {
        let mine = bubble("my-reminder", minutes: 30)
        let rig = rig(stored: [mine])
        XCTAssertTrue(rig.engine.automations.contains { $0.id == AutomationDefaults.taskScanID }, "the engine runs it")
        XCTAssertEqual(rig.store.automations.map(\.id), ["my-reminder"])
        guard case .success(let listed) = await rig.service.call("list", [:], by: "agent:mcp"), let rows = listed as? [[String: Any]] else {
            return XCTFail("list failed")
        }
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["my-reminder"])
        if case .success = await rig.service.call("get", ["id": AutomationDefaults.taskScanID], by: "agent:mcp") { XCTFail("get found it") }
        if case .success = await rig.service.call("delete", ["id": AutomationDefaults.taskScanID], by: "agent:mcp") { XCTFail("delete found it") }
        let file = try String(contentsOf: paths.file, encoding: .utf8)
        XCTAssertFalse(file.contains(AutomationDefaults.taskScanID), "app code defines it, so it is never stored")
    }

    func testAFileCannotAskForTheScanAction() {
        let sneaky = Automation(id: "sneaky", name: "Sneaky", enabled: true, trigger: .init(type: "interval", minutes: 5, clock: "wall"),
                                action: .init(type: AutomationDefaults.taskScanAction), createdBy: "user")
        XCTAssertFalse(AutomationValidator.validate(sneaky).isEmpty)
    }

    func testAStoredAutomationEditDoesNotDropTheSystemOne() async {
        let rig = rig()
        try? rig.store.replace([bubble("later", minutes: 30)])
        XCTAssertTrue(rig.engine.automations.contains { $0.id == AutomationDefaults.taskScanID })
        XCTAssertTrue(rig.engine.automations.contains { $0.id == "later" })
    }
}

/// The task scan replaced Screen review.
@MainActor
final class ScreenReviewMigrationTests: AutomationTestCase {
    private func legacy(enabled: Bool, prompt: String = "{{prompt.screen-review}}") -> Automation {
        Automation(id: "screen-review", name: "Screen review", enabled: enabled, trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: prompt, session: "own", report: "chat"), createdBy: "user")
    }

    private func store(_ list: [Automation]) -> AutomationStore {
        try? FileManager.default.removeItem(at: paths.file)
        return AutomationStore(paths: paths, defaults: { list }, watch: false)
    }

    func testAnEnabledScreenReviewIsRemovedAndTheScansScreenSourceStartsOn() {
        let automations = store([legacy(enabled: true), bubble("mine", minutes: 30)])
        let config = ConfigStore(memory: Config())
        XCTAssertFalse(config.config.tasks.scanScreen)
        XCTAssertEqual(ScreenReviewMigration.run(store: automations, config: config), .removed(wasEnabled: true))
        XCTAssertEqual(automations.automations.map(\.id), ["mine"])
        XCTAssertTrue(config.config.tasks.scanScreen)
        XCTAssertEqual(AutomationStore(paths: paths, defaults: { [] }, watch: false).automations.map(\.id), ["mine"], "the file no longer has it")
    }

    func testADisabledScreenReviewIsRemovedAndTheScreenSourceStaysOff() {
        let automations = store([legacy(enabled: false)])
        let config = ConfigStore(memory: Config())
        XCTAssertEqual(ScreenReviewMigration.run(store: automations, config: config), .removed(wasEnabled: false))
        XCTAssertEqual(automations.automations, [])
        XCTAssertFalse(config.config.tasks.scanScreen)
    }

    func testASecondRunChangesNothing() {
        let automations = store([legacy(enabled: true)])
        let config = ConfigStore(memory: Config())
        ScreenReviewMigration.run(store: automations, config: config)
        config.update { $0.tasks.scanScreen = false }
        XCTAssertEqual(ScreenReviewMigration.run(store: automations, config: config), .none)
        XCTAssertFalse(config.config.tasks.scanScreen, "the user's later choice stands")
    }

    func testAScreenReviewTheUserRewroteStays() {
        let automations = store([legacy(enabled: true, prompt: "Look at my screen and tell me about invoices.")])
        let config = ConfigStore(memory: Config())
        XCTAssertEqual(ScreenReviewMigration.run(store: automations, config: config), .none)
        XCTAssertEqual(automations.automations.map(\.id), ["screen-review"])
        XCTAssertFalse(config.config.tasks.scanScreen)
    }

    func testANewInstallHasNoScreenReviewAndItsPromptIsNotListed() {
        let automations = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        XCTAssertFalse(automations.automations.contains { $0.id == "screen-review" })
        XCTAssertFalse(Prompts.catalog.contains { $0.id == "screen-review" })
        XCTAssertTrue(Prompts.catalog.contains { $0.id == "task-scan" })
        XCTAssertNil(BuiltInPromptsData.all.first { $0.id == "screen-review" })
    }
}
