import Foundation

/// What one agent process is started with: the agent's CLI, model and instructions, from its record. Two launches that are equal need
/// no restart.
package struct AgentLaunch: Equatable, Sendable {
    package init(agentID: String, name: String, cli: String, model: String?, instructions: String) {
        self.agentID = agentID
        self.name = name
        self.cli = cli
        self.model = model
        self.instructions = instructions
    }

    package init(_ record: AgentRecord) {
        self.init(agentID: record.id, name: record.name, cli: record.agentCli, model: record.model, instructions: record.instructions)
    }

    package var agentID: String
    package var name: String
    package var cli: String
    package var model: String?
    package var instructions: String
}

/// One running agent process, as the supervisor sees it. The Mac app's is the agent's chat runtime; a test's is a fake.
@MainActor
package protocol AgentProcess: AnyObject {
    /// Called once when the process ends without `stop()`. The supervisor restarts it after a delay.
    var onCrash: (@MainActor () -> Void)? { get set }
    /// Ends the process. Does not call `onCrash`.
    func stop()
}

@MainActor
package protocol AgentProcessLauncher {
    /// Starts a process for one agent. A throw counts as a crash.
    func launch(_ launch: AgentLaunch) throws -> AgentProcess
}

/// How long to wait before restarting an agent whose process keeps ending: `initial`, then doubled each time, up to `cap`.
package struct RestartBackoff: Equatable, Sendable {
    package init(initial: TimeInterval = 1, cap: TimeInterval = 60, stableAfter: TimeInterval = 30) {
        self.initial = initial
        self.cap = cap
        self.stableAfter = stableAfter
    }

    package var initial: TimeInterval
    package var cap: TimeInterval
    /// A process that ran this long counts as healthy, so the next crash starts again from `initial`.
    package var stableAfter: TimeInterval

    /// The delay before restart number `attempt`, counting from 1.
    package func delay(attempt: Int) -> TimeInterval {
        min(cap, initial * pow(2, Double(max(0, attempt - 1))))
    }
}

/// Runs one agent process for each enabled agent. It starts the ones that are missing, stops the ones that were disabled or deleted,
/// restarts the ones whose CLI, model or instructions changed, and restarts a crashed one after a growing delay without touching the
/// others. The node owns one. Shared node services (the scheduler, screen capture, the memory pass and the task scan) are not agents
/// and are not started here.
@MainActor
package final class AgentSupervisor {
    /// Runs `work` after `delay` seconds and returns a function that cancels it. Tests pass a clock they advance by hand.
    package typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    private struct Entry {
        var launch: AgentLaunch
        var process: AgentProcess?
        var startedAt: Date
        var attempts: Int
        var cancelRestart: (() -> Void)?
    }

    /// Fires before the set of running agents changes.
    package let changes = ChangeSignal()
    private let records: () -> [AgentRecord]
    private let launcher: AgentProcessLauncher
    private let schedule: Schedule
    private let backoff: RestartBackoff
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private var observing: [ChangeToken] = []
    private var stopped = false

    package init(records: @escaping () -> [AgentRecord], launcher: AgentProcessLauncher, backoff: RestartBackoff = RestartBackoff(),
                 now: @escaping () -> Date = Date.init, schedule: @escaping Schedule = AgentSupervisor.realSchedule) {
        self.records = records
        self.launcher = launcher
        self.backoff = backoff
        self.now = now
        self.schedule = schedule
    }

    /// Follows the registry: each change to an agent runs `reconcile` on the next main-actor turn.
    package convenience init(registry: AgentRegistry, launcher: AgentProcessLauncher, backoff: RestartBackoff = RestartBackoff()) {
        self.init(records: { registry.list() }, launcher: launcher, backoff: backoff)
        observing = [registry.changes.observe { [weak self] in
            // The registry signals before it writes, so read it on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reconcile() } }
        }]
    }

    package nonisolated static let realSchedule: Schedule = { delay, work in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            work()
        }
        return { task.cancel() }
    }

    // MARK: Reading

    /// The agents that have a process now, with what each was started with.
    package var running: [String: AgentLaunch] { entries.filter { $0.value.process != nil }.mapValues(\.launch) }

    /// The agents that are enabled but wait for a restart after a crash.
    package var waiting: Set<String> { Set(entries.filter { $0.value.process == nil }.keys) }

    /// How many times in a row this agent's process ended before it stayed up.
    package func attempts(_ agentID: String) -> Int { entries[agentID]?.attempts ?? 0 }

    // MARK: Changing

    /// Makes the running processes match the enabled agents. Safe to call at any time.
    package func reconcile() {
        guard !stopped else { return }
        let wanted = Dictionary(records().filter(\.enabled).map { ($0.id, AgentLaunch($0)) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for id in entries.keys where wanted[id] == nil {
            if !changed { changes.send(); changed = true }
            end(id)
        }
        for (id, launch) in wanted.sorted(by: { $0.key < $1.key }) {
            if var entry = entries[id] {
                guard entry.launch != launch else { continue }
                if !changed { changes.send(); changed = true }
                entry.cancelRestart?()
                entry.process?.stop()
                entries[id] = Entry(launch: launch, process: nil, startedAt: now(), attempts: 0, cancelRestart: nil)
                start(id)
            } else {
                if !changed { changes.send(); changed = true }
                entries[id] = Entry(launch: launch, process: nil, startedAt: now(), attempts: 0, cancelRestart: nil)
                start(id)
            }
        }
    }

    /// Stops every process and every pending restart. The supervisor starts nothing after this.
    package func stopAll() {
        stopped = true
        observing = []
        if !entries.isEmpty { changes.send() }
        for id in Array(entries.keys) { end(id) }
    }

    private func end(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.cancelRestart?()
        entry.process?.onCrash = nil
        entry.process?.stop()
    }

    private func start(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.cancelRestart = nil
        do {
            let process = try launcher.launch(entry.launch)
            entry.process = process
            entry.startedAt = now()
            entries[id] = entry
            process.onCrash = { [weak self, weak process] in
                guard let self, let process else { return }
                self.crashed(id, process)
            }
        } catch {
            entry.process = nil
            entries[id] = entry
            scheduleRestart(id)
        }
    }

    private func crashed(_ id: String, _ process: AgentProcess) {
        guard var entry = entries[id], entry.process === process else { return }
        entry.process?.onCrash = nil
        entry.process = nil
        if now().timeIntervalSince(entry.startedAt) >= backoff.stableAfter { entry.attempts = 0 }
        entries[id] = entry
        changes.send()
        scheduleRestart(id)
    }

    private func scheduleRestart(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.attempts += 1
        let delay = backoff.delay(attempt: entry.attempts)
        entry.cancelRestart = schedule(delay) { [weak self] in
            guard let self, self.entries[id] != nil, !self.stopped else { return }
            self.start(id)
        }
        entries[id] = entry
    }
}
