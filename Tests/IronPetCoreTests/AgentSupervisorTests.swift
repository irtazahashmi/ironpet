import XCTest
@testable import IronPetCore

/// A launcher that starts fake processes and records what it was asked to start.
@MainActor
final class FakeLauncher: AgentProcessLauncher {
    final class Process: AgentProcess {
        var onCrash: (@MainActor () -> Void)?
        var stopped = false
        let launch: AgentLaunch
        init(_ launch: AgentLaunch) { self.launch = launch }
        func stop() { stopped = true }
        func crash() { stopped = true; onCrash?() }
    }

    struct Failure: Error {}
    var launched: [Process] = []
    var failNext = 0

    func launch(_ launch: AgentLaunch) throws -> AgentProcess {
        if failNext > 0 { failNext -= 1; throw Failure() }
        let process = Process(launch)
        launched.append(process)
        return process
    }

    func live(_ agent: String) -> [Process] { launched.filter { $0.launch.agentID == agent && !$0.stopped } }
}

/// A clock and a timer list the test moves by hand.
@MainActor
final class ManualClock {
    var time = Date(timeIntervalSince1970: 1_000)
    private var timers: [(id: Int, due: Date, work: @MainActor () -> Void)] = []
    private var nextID = 0
    private(set) var delays: [TimeInterval] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        delays.append(delay)
        timers.append((id, time.addingTimeInterval(delay), work))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func advance(_ seconds: TimeInterval) {
        time = time.addingTimeInterval(seconds)
        let due = timers.filter { $0.due <= time }.sorted { $0.due < $1.due }
        timers.removeAll { entry in due.contains { $0.id == entry.id } }
        for entry in due { entry.work() }
    }

    var pending: Int { timers.count }
}

@MainActor
final class AgentSupervisorTests: XCTestCase {
    private var records: [AgentRecord] = []
    private let launcher = FakeLauncher()
    private let clock = ManualClock()

    override func setUp() async throws {
        try await super.setUp()
        records = [AgentRecord(id: "agent_default", number: 1, name: "Ghost", agentCli: "cursor"),
                   AgentRecord(id: "agent_b", number: 2, name: "Bunny", agentCli: "claude", model: "opus", instructions: "Be brief.")]
    }

    private func supervisor(backoff: RestartBackoff = RestartBackoff(initial: 1, cap: 8, stableAfter: 30)) -> AgentSupervisor {
        AgentSupervisor(records: { [unowned self] in records }, launcher: launcher, backoff: backoff,
                        now: { [unowned self] in clock.time }, schedule: { [unowned self] in clock.schedule($0, $1) })
    }

    // MARK: S1, one process per enabled agent

    func testItStartsOneProcessPerEnabledAgentWithThatAgentsConfiguration() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        XCTAssertEqual(launcher.launched.count, 2)
        XCTAssertEqual(supervisor.running["agent_default"], AgentLaunch(agentID: "agent_default", name: "Ghost", cli: "cursor", model: nil, instructions: ""))
        XCTAssertEqual(supervisor.running["agent_b"], AgentLaunch(agentID: "agent_b", name: "Bunny", cli: "claude", model: "opus", instructions: "Be brief."))
        supervisor.reconcile()
        XCTAssertEqual(launcher.launched.count, 2, "a second reconcile starts nothing")
    }

    func testACrashRestartsOnlyThatAgentAfterTheBackoff() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        let b = launcher.live("agent_b")[0]
        let a = launcher.live("agent_default")[0]
        b.crash()
        XCTAssertEqual(supervisor.waiting, ["agent_b"])
        XCTAssertNil(supervisor.running["agent_b"])
        XCTAssertFalse(a.stopped, "the other agent's process is untouched")
        XCTAssertNotNil(supervisor.running["agent_default"])
        clock.advance(0.5)
        XCTAssertEqual(launcher.launched.count, 2, "not before the delay")
        clock.advance(0.6)
        XCTAssertEqual(launcher.launched.count, 3)
        XCTAssertEqual(launcher.live("agent_b").count, 1)
        XCTAssertEqual(launcher.live("agent_default").first === a, true)
    }

    func testTheBackoffDoublesAndStopsAtTheCap() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        for _ in 0..<6 {
            launcher.live("agent_b")[0].crash()
            clock.advance(100)
        }
        XCTAssertEqual(clock.delays, [1, 2, 4, 8, 8, 8], "capped, so a broken CLI does not spin")
        XCTAssertEqual(supervisor.attempts("agent_b"), 6)
    }

    func testAProcessThatStaysUpResetsTheBackoff() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        launcher.live("agent_b")[0].crash()
        clock.advance(2)
        launcher.live("agent_b")[0].crash()
        clock.advance(10)
        XCTAssertEqual(clock.delays, [1, 2])
        clock.advance(60)
        launcher.live("agent_b")[0].crash()
        XCTAssertEqual(clock.delays.last, 1, "it ran longer than stableAfter, so the next delay starts over")
    }

    func testALaunchThatThrowsIsRetriedWithBackoff() async {
        let supervisor = supervisor()
        launcher.failNext = 2
        supervisor.reconcile()
        XCTAssertEqual(supervisor.running.count, 0)
        XCTAssertEqual(supervisor.waiting.count, 2)
        clock.advance(1)
        clock.advance(10)
        XCTAssertEqual(supervisor.running.count, 2)
    }

    func testStoppingTheNodeStopsEveryProcessAndEveryPendingRestart() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        launcher.live("agent_b")[0].crash()
        let a = launcher.live("agent_default")[0]
        supervisor.stopAll()
        XCTAssertTrue(a.stopped)
        XCTAssertEqual(clock.pending, 0)
        clock.advance(100)
        XCTAssertEqual(launcher.launched.count, 2, "nothing restarts after stopAll")
        supervisor.reconcile()
        XCTAssertEqual(launcher.launched.count, 2)
        XCTAssertTrue(supervisor.running.isEmpty)
    }

    // MARK: S3, disabling and enabling

    func testDisablingAnAgentStopsItsProcessAndEnablingStartsItAgain() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        let first = launcher.live("agent_b")[0]
        records[1].enabled = false
        supervisor.reconcile()
        XCTAssertTrue(first.stopped)
        XCTAssertNil(supervisor.running["agent_b"])
        XCTAssertNotNil(supervisor.running["agent_default"])
        records[1].enabled = true
        supervisor.reconcile()
        XCTAssertEqual(launcher.live("agent_b").count, 1)
        XCTAssertTrue(launcher.live("agent_b")[0] !== first)
    }

    func testADisabledAgentStartsNoProcess() async {
        records[1].enabled = false
        let supervisor = supervisor()
        supervisor.reconcile()
        XCTAssertEqual(launcher.launched.map { $0.launch.agentID }, ["agent_default"])
    }

    func testDisablingACrashedAgentCancelsItsRestart() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        launcher.live("agent_b")[0].crash()
        records[1].enabled = false
        supervisor.reconcile()
        XCTAssertEqual(clock.pending, 0)
        clock.advance(100)
        XCTAssertEqual(launcher.launched.count, 2)
    }

    // MARK: S4, the supervisor reacts to configuration

    func testAChangedConfigurationRestartsOnlyThatAgent() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        let a = launcher.live("agent_default")[0]
        let old = launcher.live("agent_b")[0]
        records[1].model = "sonnet"
        supervisor.reconcile()
        XCTAssertTrue(old.stopped)
        XCTAssertFalse(a.stopped)
        XCTAssertEqual(launcher.live("agent_b")[0].launch.model, "sonnet")
    }

    func testARenameDoesNotRestart() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        let old = launcher.live("agent_b")[0]
        records[1].name = "Rabbit"
        supervisor.reconcile()
        XCTAssertFalse(old.stopped)
        XCTAssertEqual(launcher.launched.count, 2)
        XCTAssertEqual(supervisor.running["agent_b"]?.name, "Rabbit")
    }

    func testANewAgentStartsAndADeletedOneStops() async {
        let supervisor = supervisor()
        supervisor.reconcile()
        let b = launcher.live("agent_b")[0]
        records.append(AgentRecord(id: "agent_c", number: 3, name: "Cat", agentCli: "codex"))
        records.remove(at: 1)
        supervisor.reconcile()
        XCTAssertTrue(b.stopped)
        XCTAssertEqual(Set(supervisor.running.keys), ["agent_default", "agent_c"])
    }

    // MARK: S8, an install with one agent

    func testWithOnlyAgentOneTheLaunchIsTheDefaultConfiguration() async {
        records = [records[0]]
        let supervisor = supervisor()
        supervisor.reconcile()
        XCTAssertEqual(launcher.launched.count, 1)
        XCTAssertEqual(launcher.launched[0].launch, AgentLaunch(agentID: "agent_default", name: "Ghost", cli: "cursor", model: nil, instructions: ""))
    }

    func testBackoffDelays() async {
        let backoff = RestartBackoff(initial: 1, cap: 60)
        XCTAssertEqual((1...8).map { backoff.delay(attempt: $0) }, [1, 2, 4, 8, 16, 32, 60, 60])
    }
}

/// The registry side of S3 and S4: creating, enabling, disabling and deleting an agent.
@MainActor
final class AgentRegistryLifecycleTests: XCTestCase {
    private func registry() throws -> AgentRegistry {
        AgentRegistry(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    func testCreateAddsAnEnabledAgentWithTheNextNumber() async throws {
        let registry = try registry()
        let b = try registry.create(name: "Bunny", pet: "/tmp/bunny.png", agentCli: "claude", model: "opus", instructions: "Be brief.")
        XCTAssertEqual(b.number, 2)
        XCTAssertTrue(b.enabled)
        XCTAssertTrue(b.id.hasPrefix("agent_"))
        let stored = try XCTUnwrap(registry.get(b.id))
        XCTAssertEqual([stored.name, stored.pet, stored.agentCli, stored.model, stored.instructions], ["Bunny", "/tmp/bunny.png", "claude", "opus", "Be brief."])
        XCTAssertEqual(registry.list().map(\.number), [1, 2])
    }

    func testCreateRejectsAnEmptyNameAndAnUnknownCli() async throws {
        let registry = try registry()
        XCTAssertThrowsError(try registry.create(name: "  ", agentCli: "claude"))
        XCTAssertThrowsError(try registry.create(name: "X", agentCli: "no-such-cli"))
        XCTAssertEqual(registry.list().count, 1)
    }

    func testANumberIsNeverReusedAfterADelete() async throws {
        let registry = try registry()
        let b = try registry.create(name: "B", agentCli: "claude")
        try registry.delete(b.id)
        let c = try registry.create(name: "C", agentCli: "claude")
        XCTAssertEqual(c.number, 3)
    }

    func testDisableAndEnableKeepTheRecord() async throws {
        let registry = try registry()
        let b = try registry.create(name: "B", agentCli: "claude", model: "opus")
        try registry.update(b.id, AgentRecordPatch(enabled: false))
        XCTAssertEqual(registry.enabledAgents().map(\.id), ["agent_default"])
        XCTAssertEqual(registry.get(b.id)?.enabled, false)
        XCTAssertEqual(registry.get(b.id)?.model, "opus")
        try registry.update(b.id, AgentRecordPatch(enabled: true))
        XCTAssertEqual(registry.enabledAgents().count, 2)
    }

    func testAgentOneCannotBeDeletedOrDisabled() async throws {
        let registry = try registry()
        XCTAssertThrowsError(try registry.delete("agent_default"))
        XCTAssertThrowsError(try registry.update("agent_default", AgentRecordPatch(enabled: false)))
        XCTAssertEqual(registry.get("agent_default")?.enabled, true)
    }

    func testAnUnknownIdIsNotFound() async throws {
        let registry = try registry()
        XCTAssertThrowsError(try registry.delete("agent_nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertThrowsError(try registry.update("agent_nope", AgentRecordPatch(name: "x"))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testSupervisorFollowsTheRegistry() async throws {
        let registry = try registry()
        let launcher = FakeLauncher()
        let supervisor = AgentSupervisor(registry: registry, launcher: launcher)
        supervisor.reconcile()
        XCTAssertEqual(supervisor.running.count, 1)
        let b = try registry.create(name: "B", agentCli: "claude")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(Set(supervisor.running.keys), ["agent_default", b.id])
        try registry.update(b.id, AgentRecordPatch(enabled: false))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(Set(supervisor.running.keys), ["agent_default"])
        supervisor.stopAll()
    }

    func testAnOlderWireRecordWithoutEnabledDecodesAsEnabled() async throws {
        let json = #"{"id":"agent_x","number":2,"name":"X","agentCli":"claude","instructions":"","permissions":{},"cliModels":{},"created":0,"updated":0}"#
        let record = try JSONDecoder().decode(AgentRecord.self, from: Data(json.utf8))
        XCTAssertTrue(record.enabled)
    }
}

/// The pet set and the agent switcher: S3 and S5 as plain values.
final class AgentPetSetTests: XCTestCase {
    private func agent(_ id: String, _ number: Int, _ name: String, enabled: Bool = true, pet: String? = nil) -> AgentRecord {
        AgentRecord(id: id, number: number, name: name, pet: pet, agentCli: "cursor", enabled: enabled)
    }

    func testThereIsOnePetForEachEnabledAgentInAgentOrder() {
        let slots = AgentPetSet.slots(for: [agent("b", 2, "Bunny", pet: "/tmp/b.png"), agent("a", 1, "Ghost"), agent("c", 3, "Cat", enabled: false)])
        XCTAssertEqual(slots.map(\.agentID), ["a", "b"])
        XCTAssertEqual(slots.map(\.index), [0, 1])
        XCTAssertEqual(slots[1].sprite, "/tmp/b.png", "each pet shows its own agent's sprite")
        XCTAssertEqual(slots[0].offsetX, 0)
        XCTAssertGreaterThan(slots[1].offsetX, 0, "the second pet stands beside the first")
    }

    func testDisablingAnAgentRemovesItsPetAndEnablingBringsItBack() {
        var records = [agent("a", 1, "Ghost"), agent("b", 2, "Bunny")]
        XCTAssertEqual(AgentPetSet.slots(for: records).count, 2)
        records[1].enabled = false
        XCTAssertEqual(AgentPetSet.slots(for: records).map(\.agentID), ["a"])
        records[1].enabled = true
        XCTAssertEqual(AgentPetSet.slots(for: records).map(\.agentID), ["a", "b"])
    }

    func testAClickOnAPetOpensThatAgentsChat() {
        let slots = AgentPetSet.slots(for: [agent("a", 1, "Ghost"), agent("b", 2, "Bunny")])
        XCTAssertEqual(AgentPetSet.chatTarget(clicked: "b", in: slots), "b")
        XCTAssertEqual(AgentPetSet.chatTarget(clicked: "a", in: slots), "a")
        XCTAssertNil(AgentPetSet.chatTarget(clicked: "gone", in: slots))
    }

    func testTheSwitcherListsEnabledAgentsAndRoutesAPick() {
        let switcher = AgentSwitcher(records: [agent("a", 1, "Ghost"), agent("b", 2, "Bunny"), agent("c", 3, "Cat", enabled: false)], current: "a")
        XCTAssertTrue(switcher.isVisible)
        XCTAssertEqual(switcher.choices.map(\.name), ["Ghost", "Bunny"])
        XCTAssertEqual(switcher.choices.map(\.isCurrent), [true, false])
        XCTAssertEqual(switcher.target(picking: "b"), "b")
        XCTAssertNil(switcher.target(picking: "a"), "the chat already shown")
        XCTAssertNil(switcher.target(picking: "c"), "a disabled agent has no chat to open")
    }

    func testWithOneAgentThereIsNoSwitcher() {
        XCTAssertFalse(AgentSwitcher(records: [agent("a", 1, "Ghost")], current: "a").isVisible)
    }
}
