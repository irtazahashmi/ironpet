import XCTest
@testable import IronPet
@testable import IronPetCore

/// The `inbox` trigger: one run for each item that arrives after the automation exists.
@MainActor
final class AutomationInboxTriggerTests: AutomationTestCase {
    private var tasks: TaskStore!
    private var commands: [String] = []
    /// Held so the service the store reports to stays alive.
    private var current: Rig?

    private func rig(_ automation: Automation) -> Rig {
        let rig = makeRig([automation])
        commands = []
        rig.service.runShell = { [unowned self] command, _ in
            commands.append(command)
            return CommandResult(code: 0, stdout: "ok")
        }
        tasks = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, now: { [clock] in clock!.now })
        tasks.onAdded = { [weak service = rig.service] items in service?.inboxItemsAdded(items) }
        current = rig
        return rig
    }

    private func inboxAutomation(createdBy: String = "user") -> Automation {
        Automation(id: "on-new", name: "On new", trigger: .init(type: "inbox"),
                   action: .init(type: "shell", command: "echo {{item.title}}"), createdBy: createdBy)
    }

    private func add(_ key: String, _ title: String) {
        tasks.suggest(.init(key: key, title: title), agent: .email, sourceRef: "mail:\(key)")
    }

    func testTheValidatorAcceptsTheTriggerAndRejectsFieldsItDoesNotUse() {
        XCTAssertEqual(AutomationValidator.validate(inboxAutomation()), [])
        var bad = inboxAutomation()
        bad.trigger.minutes = 5
        XCTAssertEqual(AutomationValidator.validate(bad), ["trigger.minutes does not apply to an inbox trigger"])
    }

    func testItRunsOncePerNewItemWithThatItem() async {
        _ = rig(inboxAutomation())
        add("a", "Reply to Ana")
        await until("first run") { self.commands.count == 1 }
        XCTAssertEqual(commands, ["echo 'Reply to Ana'"])
        add("b", "Book the room")
        await until("second run") { self.commands.count == 2 }
        XCTAssertEqual(commands.last, "echo 'Book the room'")
    }

    func testItemsAlreadyInTheInboxDoNotRunANewAutomation() async throws {
        let database = Database.open(path: nil, migrations: AppMigrations.all).database
        let before = TaskStore(database: database)
        before.suggest(.init(key: "old", title: "Already here"), agent: .email, sourceRef: "mail:old")
        let rig = makeRig([inboxAutomation()])
        current = rig
        commands = []
        rig.service.runShell = { [unowned self] command, _ in commands.append(command); return CommandResult(code: 0, stdout: "ok") }
        let reopened = TaskStore(database: database)
        reopened.onAdded = { [weak service = rig.service] items in service?.inboxItemsAdded(items) }
        XCTAssertEqual(reopened.suggestions.count, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(commands, [], "the item was there before, so nothing runs")
        reopened.suggest(.init(key: "new", title: "Fresh"), agent: .email, sourceRef: "mail:new")
        await until("run for the new item") { self.commands.count == 1 }
        XCTAssertEqual(commands, ["echo 'Fresh'"])
    }

    func testAnItemTheAutomationFiledItselfDoesNotRunItAgain() async throws {
        let rig = rig(inboxAutomation())
        tasks.suggest([.init(key: "k", title: "Filed by the watcher")], automation: "on-new", name: "On new")
        _ = rig
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(commands, [])
    }

    func testAShellActionAnAgentWroteWaitsForApprovalAndTheItemTextIsQuoted() async throws {
        let rig = rig(inboxAutomation(createdBy: "agent:mcp"))
        add("a", "Before approval")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(commands, [], "an unapproved command does not run")
        XCTAssertTrue(rig.service.needsApproval(rig.store.automations[0]))
        rig.service.approve("on-new")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(commands, [], "an item that came before the approval is dropped, as a stream event is")
        add("b", "x'; rm -rf ~; echo '")
        await until("approved run") { self.commands.count == 1 }
        XCTAssertEqual(commands, ["echo 'x'\\''; rm -rf ~; echo '\\'''"], "the title is one quoted word")
    }

    func testADisabledAutomationDoesNotRun() async throws {
        var a = inboxAutomation()
        a.enabled = false
        _ = rig(a)
        add("a", "Reply to Ana")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(commands, [])
    }
}
