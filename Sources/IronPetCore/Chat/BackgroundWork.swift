import Foundation

/// What kind of background work a row is.
package enum BackgroundKind: String, Codable, CaseIterable {
    /// A subagent the main agent started (a tool call with child tool calls).
    case agent
    /// A shell command started with `run_in_background`.
    case shell
    case monitor
    case workflow
    /// An IronPet job (`jobs_start`).
    case job
}

package enum BackgroundState: String, Codable {
    case running
    /// Needs the user's approval before it goes on.
    case waiting
    case done
    case failed
    case stopped

    package var isFinished: Bool { self == .done || self == .failed || self == .stopped }
}

/// One row of the background work list. The Mac builds them and sends them to the iPhone as they are.
package struct BackgroundItem: Identifiable, Codable, Equatable {
    package init(id: String, kind: BackgroundKind, title: String, state: BackgroundState = .running, now: String? = nil, steps: Int = 0,
                 startedAt: Date, endedAt: Date? = nil, waitingFor: String? = nil, result: String? = nil, outputFile: String? = nil,
                 canStop: Bool = false, stopHint: String? = nil, lines: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.now = now
        self.steps = steps
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.waitingFor = waitingFor
        self.result = result
        self.outputFile = outputFile
        self.canStop = canStop
        self.stopHint = stopHint
        self.lines = lines
    }

    /// Unique in the chat: the tool-use id of an agent, the async task id of the rest, `job:<id>` for a job.
    package let id: String
    package var kind: BackgroundKind
    package var title: String
    package var state: BackgroundState
    /// What it does right now: an agent's current tool, a shell's last output line.
    package var now: String?
    /// Tool calls an agent made, or tool calls a workflow reported.
    package var steps: Int
    package var startedAt: Date
    package var endedAt: Date?
    /// What an item in `waiting` waits for.
    package var waitingFor: String?
    /// The final line of a finished item.
    package var result: String?
    /// A shell's, monitor's or workflow's output file on the Mac.
    package var outputFile: String?
    package var canStop: Bool
    /// Why an item has no Stop, shown in its open row.
    package var stopHint: String?
    /// The open row's body: an agent's or job's steps, a shell's output tail. Oldest first.
    package var lines: [String]

    /// How long it ran, or has run so far.
    package func elapsed(at date: Date) -> TimeInterval { max(0, (endedAt ?? date).timeIntervalSince(startedAt)) }

    /// True for an item that can be stopped now.
    package var stoppable: Bool { canStop && !state.isFinished }
}

/// What the capsule above the input shows.
package enum BackgroundIndicator: Equatable {
    case idle
    case running(Int)
    case waiting(Int)
    case failed(Int)

    package var count: Int {
        switch self {
        case .idle: return 0
        case .running(let count), .waiting(let count), .failed(let count): return count
        }
    }
}

/// The background work of one chat. It owns the rows, the order they appear in and what the user has seen.
package struct BackgroundWorkList: Equatable {
    package init() {}

    package private(set) var items: [BackgroundItem] = []
    /// Failed items the user has not yet seen by opening the list.
    private var unseenFailures: Set<String> = []
    /// Items that Clear finished removed. A later update to one does not bring it back.
    private var cleared: Set<String> = []
    /// Longest output or step list kept per row.
    package static let lineLimit = 40

    package var isEmpty: Bool { items.isEmpty }
    package func item(_ id: String) -> BackgroundItem? { items.first { $0.id == id } }

    /// Adds the item or changes the one with its id, and keeps what a later update leaves out. A finished item that the user
    /// cleared stays gone.
    package mutating func upsert(_ id: String, make: () -> BackgroundItem, change: (inout BackgroundItem) -> Void) {
        guard !cleared.contains(id) else { return }
        if let index = items.firstIndex(where: { $0.id == id }) {
            let before = items[index]
            change(&items[index])
            noteTransition(from: before.state, to: items[index])
        } else {
            var item = make()
            change(&item)
            items.append(item)
            noteTransition(from: .running, to: item)
        }
    }

    private mutating func noteTransition(from old: BackgroundState, to item: BackgroundItem) {
        if item.state == .failed, old != .failed { unseenFailures.insert(item.id) }
        if item.state != .failed { unseenFailures.remove(item.id) }
    }

    /// The user opened the list: failures count as seen.
    package mutating func markSeen() { unseenFailures = [] }

    /// Removes done, failed and stopped items. Running and waiting ones stay.
    package mutating func clearFinished() {
        for item in items where item.state.isFinished { cleared.insert(item.id) }
        items.removeAll { $0.state.isFinished }
        unseenFailures = []
    }

    /// Forgets everything, for a new chat.
    package mutating func reset() { self = BackgroundWorkList() }

    /// Failed (until the user opens the list) beats waiting beats running beats idle, as in the approved design.
    package var indicator: BackgroundIndicator {
        let failed = items.filter { unseenFailures.contains($0.id) }.count
        if failed > 0 { return .failed(failed) }
        let waiting = items.filter { $0.state == .waiting }.count
        if waiting > 0 { return .waiting(waiting) }
        let running = items.filter { $0.state == .running }.count
        return running > 0 ? .running(running) : .idle
    }

    /// Newest first among the active ones, then the finished ones, newest first.
    package var ordered: [BackgroundItem] {
        let active = items.filter { !$0.state.isFinished }.reversed()
        let finished = items.filter { $0.state.isFinished }.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        return Array(active) + finished
    }

    /// The text of an idle list: what finished today, or that nothing ran.
    package func idleSummary(now: Date, calendar: Calendar = .current) -> String {
        let today = items.filter { $0.state.isFinished && calendar.isDate($0.endedAt ?? $0.startedAt, inSameDayAs: now) }
        guard !today.isEmpty else { return "Nothing ran in the background." }
        return "\(today.count) finished today."
    }
}

// MARK: Mapping from agent traffic

/// The three updates the adapter sends for background tasks. The `async_task_*` names are its own.
package struct AsyncTaskUpdate: Equatable {
    package enum Phase: Equatable { case spawned, progress, state }
    package var phase: Phase
    package var id: String
    package var taskType: String?
    package var description: String?
    package var summary: String?
    package var lastToolName: String?
    package var toolCalls: Int?
    package var state: String?
    package var outputFile: String?
    package var canStop: Bool?

    package init(phase: Phase, id: String, taskType: String? = nil, description: String? = nil, summary: String? = nil, lastToolName: String? = nil,
                 toolCalls: Int? = nil, state: String? = nil, outputFile: String? = nil, canStop: Bool? = nil) {
        self.phase = phase
        self.id = id
        self.taskType = taskType
        self.description = description
        self.summary = summary
        self.lastToolName = lastToolName
        self.toolCalls = toolCalls
        self.state = state
        self.outputFile = outputFile
        self.canStop = canStop
    }

    /// Reads one `session/update` payload, or nil when it is not an async task update.
    package init?(update: [String: Any]) {
        guard let kind = update["sessionUpdate"] as? String, let id = update["asyncTaskId"] as? String, !id.isEmpty else { return nil }
        switch kind {
        case "async_task_spawned": phase = .spawned
        case "async_task_progress": phase = .progress
        case "async_task_state_update": phase = .state
        default: return nil
        }
        self.id = id
        func text(_ key: String) -> String? { (update[key] as? String).flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 } }
        taskType = text("taskType")
        description = text("description") ?? text("name")
        summary = text("summary")
        lastToolName = text("lastToolName")
        let usage = update["usage"] as? [String: Any]
        toolCalls = (usage?["toolUses"] as? NSNumber)?.intValue ?? (usage?["toolCalls"] as? NSNumber)?.intValue
        state = text("state")
        outputFile = text("outputFilePath")
        canStop = (update["canStop"] as? NSNumber)?.boolValue
    }
}

package extension BackgroundKind {
    /// The adapter's task types: `shell`, `monitor`, `workflow`. Anything else is a plain background command.
    init(taskType: String?) {
        switch taskType?.lowercased() {
        case "monitor": self = .monitor
        case "workflow": self = .workflow
        default: self = .shell
        }
    }
}

package extension BackgroundWorkList {
    /// Applies one async task update.
    mutating func apply(_ update: AsyncTaskUpdate, now: Date) {
        let kind = BackgroundKind(taskType: update.taskType)
        upsert(update.id, make: {
            BackgroundItem(id: update.id, kind: kind, title: update.description ?? "Background task", startedAt: now)
        }, change: { item in
            // Only the spawn names the task type. A later update keeps the row's kind.
            let kind = update.taskType == nil ? item.kind : kind
            if update.phase == .spawned {
                item.kind = kind
                // A monitor has no Stop, whatever the adapter says.
                item.canStop = kind != .monitor && (update.canStop ?? true)
                if kind == .monitor { item.stopHint = "A monitor ends on its own" }
            }
            if let description = update.description, update.phase != .progress || item.title == "Background task" { item.title = description }
            if let file = update.outputFile { item.outputFile = file }
            if let calls = update.toolCalls { item.steps = calls }
            if let summary = update.summary, update.phase == .progress { item.now = summary }
            if let tool = update.lastToolName, kind == .workflow { item.lines = Self.appended(item.lines, "Tool: \(tool)") }
            if update.phase == .state, let state = update.state { Self.finish(&item, state: state, summary: update.summary, now: now) }
        })
    }

    /// Sets a shell's or monitor's output tail. The last line is its "now" line.
    mutating func setOutput(_ id: String, lines: [String]) {
        guard !lines.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lines = Array(lines.suffix(Self.lineLimit))
        items[index].now = lines.last
    }

    /// Drops what the chat started and keeps the IronPet jobs, which belong to the Mac and outlive a chat.
    mutating func dropChatWork() {
        let jobs = items.filter { $0.kind == .job }
        self = BackgroundWorkList()
        items = jobs
    }

    private static func finish(_ item: inout BackgroundItem, state: String, summary: String?, now: Date) {
        switch state {
        case "completed": item.state = .done
        case "failed": item.state = .failed
        case "stopped": item.state = .stopped
        case "running": item.state = .running
        default: return
        }
        if item.state.isFinished {
            item.endedAt = item.endedAt ?? now
            if let summary { item.result = summary }
        }
    }

    private static func appended(_ lines: [String], _ line: String) -> [String] {
        guard lines.last != line else { return lines }
        return Array((lines + [line]).suffix(lineLimit))
    }

    /// A subagent's tool call. `parent` is the id of the agent's own tool row.
    mutating func apply(subagentCall id: String, parent: String, summary: String, ok: Bool?, title: String, startedAt: Date, steps: Int, now: Date) {
        upsert(parent, make: {
            BackgroundItem(id: parent, kind: .agent, title: title, startedAt: startedAt, canStop: false, stopHint: "Can't stop an agent yet")
        }, change: { item in
            item.title = title
            item.steps = steps
            if ok == nil { item.now = summary }
            // A call that started and one that finished share their summary, so the step shows once.
            if !item.lines.suffix(Self.lineLimit).contains(summary) { item.lines = Self.appended(item.lines, summary) }
        })
    }

    /// The agent's own tool row finished.
    mutating func finishAgent(_ parent: String, ok: Bool, result: String?, now: Date) {
        guard let index = items.firstIndex(where: { $0.id == parent }), !items[index].state.isFinished else { return }
        let before = items[index].state
        items[index].state = ok ? .done : .failed
        items[index].endedAt = now
        items[index].now = nil
        if let result { items[index].result = result }
        noteTransition(from: before, to: items[index])
    }

    /// Mirrors the job store. A job shows while it is active, and for the day it finished.
    mutating func sync(jobs: [Job], now: Date, calendar: Calendar = .current) {
        for job in jobs {
            let finished = !job.state.isActive
            if finished, let ended = job.ended ?? job.started, !calendar.isDate(ended, inSameDayAs: now) { continue }
            let id = "job:\(job.id)"
            // An interrupted job has nothing running behind it.
            let state: BackgroundState
            switch job.state {
            case .queued, .running: state = .running
            case .needsApproval: state = .waiting
            case .done: state = .done
            case .failed, .interrupted: state = .failed
            case .stopped: state = .stopped
            }
            upsert(id, make: {
                BackgroundItem(id: id, kind: .job, title: job.title, startedAt: job.started ?? job.created)
            }, change: { item in
                item.title = job.title
                item.state = state
                item.startedAt = job.started ?? job.created
                item.endedAt = finished ? (job.ended ?? item.endedAt ?? now) : nil
                item.now = job.state == .queued ? "Waiting to start" : job.lastStep
                item.waitingFor = job.state == .needsApproval ? job.waitingFor : nil
                item.result = job.error ?? job.summary
                item.canStop = job.state.isActive
                if let step = job.lastStep { item.lines = Self.appended(item.lines, step) }
            })
        }
    }
}

/// Reads the end of a file without loading all of it.
package enum OutputTail {
    /// The last `limit` non-empty lines of the file, from at most its last 16 KB. Nil when the file cannot be read.
    package static func lines(at path: String, limit: Int = BackgroundWorkList.lineLimit) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let window: UInt64 = 16 * 1024
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // A window that starts mid-file starts mid-line.
        if size > window, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.allSatisfy(\.isWhitespace) }
        return Array(lines.suffix(limit))
    }
}
