import Foundation

/// One row of the background work list as the iPhone reads it. The Mac sends the fields of its own `BackgroundItem`, and a field
/// an older Mac leaves out decodes to its default.
public struct RemoteBackgroundItem: Codable, Equatable, Identifiable {
    public var id: String
    /// `agent`, `shell`, `monitor`, `workflow` or `job`.
    public var kind: String
    public var title: String
    /// `running`, `waiting`, `done`, `failed` or `stopped`.
    public var state: String
    public var now: String?
    public var steps: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var waitingFor: String?
    public var result: String?
    public var outputFile: String?
    public var canStop: Bool
    public var stopHint: String?
    public var lines: [String]

    enum CodingKeys: String, CodingKey {
        case id, kind, title, state, now, steps, result, canStop = "can_stop", lines
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case waitingFor = "waiting_for"
        case outputFile = "output_file"
        case stopHint = "stop_hint"
    }

    public init(id: String, kind: String, title: String, state: String = "running", now: String? = nil, steps: Int = 0, startedAt: Date,
                endedAt: Date? = nil, waitingFor: String? = nil, result: String? = nil, outputFile: String? = nil, canStop: Bool = false,
                stopHint: String? = nil, lines: [String] = []) {
        self.id = id; self.kind = kind; self.title = title; self.state = state; self.now = now; self.steps = steps; self.startedAt = startedAt
        self.endedAt = endedAt; self.waitingFor = waitingFor; self.result = result; self.outputFile = outputFile; self.canStop = canStop
        self.stopHint = stopHint; self.lines = lines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "shell"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Background work"
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "running"
        now = try c.decodeIfPresent(String.self, forKey: .now)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        outputFile = try c.decodeIfPresent(String.self, forKey: .outputFile)
        canStop = try c.decodeIfPresent(Bool.self, forKey: .canStop) ?? false
        stopHint = try c.decodeIfPresent(String.self, forKey: .stopHint)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(title, forKey: .title); try c.encode(state, forKey: .state)
        try c.encodeIfPresent(now, forKey: .now); try c.encode(steps, forKey: .steps); try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt); try c.encodeIfPresent(waitingFor, forKey: .waitingFor)
        try c.encodeIfPresent(result, forKey: .result); try c.encodeIfPresent(outputFile, forKey: .outputFile); try c.encode(canStop, forKey: .canStop)
        try c.encodeIfPresent(stopHint, forKey: .stopHint); try c.encode(lines, forKey: .lines)
    }

    public var isFinished: Bool { state == "done" || state == "failed" || state == "stopped" }
    public var stoppable: Bool { canStop && !isFinished }
}

/// What the capsule above the input shows, on either device.
public enum BackgroundCapsule: Equatable {
    case idle
    case running(Int)
    case waiting(Int)
    case failed(Int)

    /// Failed rows the user has not seen come first, then rows waiting for approval, then running ones.
    public static func make(states: [(id: String, state: String)], seenFailures: Set<String>) -> BackgroundCapsule {
        let failed = states.filter { $0.state == "failed" && !seenFailures.contains($0.id) }.count
        if failed > 0 { return .failed(failed) }
        let waiting = states.filter { $0.state == "waiting" }.count
        if waiting > 0 { return .waiting(waiting) }
        let running = states.filter { $0.state == "running" }.count
        return running > 0 ? .running(running) : .idle
    }

    public var label: String {
        switch self {
        case .idle: return "Nothing running"
        case .running(let count): return "\(count) running"
        case .waiting(let count): return "\(count) waiting for approval"
        case .failed(let count): return "\(count) failed"
        }
    }
}

/// Words and symbols the two apps share for the list.
public enum BackgroundWorkStyle {
    public static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "agent": return "Agent"
        case "monitor": return "Monitor"
        case "workflow": return "Workflow"
        case "job": return "IronPet job"
        default: return "Shell"
        }
    }

    public static func kindSymbol(_ kind: String) -> String {
        switch kind {
        case "agent": return "person.2"
        case "monitor": return "eye"
        case "workflow": return "point.3.connected.trianglepath.dotted"
        case "job": return "bolt.fill"
        default: return "terminal"
        }
    }

    /// "6:12" for a run under an hour, "1:02:03" above.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// The second line of a closed row: what it does now for a running one, the outcome for a finished one.
    public static func subtitle(state: String, now: String?, waitingFor: String?, result: String?, steps: Int, kind: String) -> String? {
        switch state {
        case "waiting": return "Needs approval" + (waitingFor.map { " · \($0)" } ?? "")
        case "done": return "Done" + (result.flatMap(firstLine).map { " · \($0)" } ?? "")
        case "failed": return "Failed" + (result.flatMap(firstLine).map { " · \($0)" } ?? "")
        case "stopped": return "Stopped"
        default:
            var parts: [String] = []
            if let now, !now.isEmpty { parts.append(now) }
            if steps > 0 { parts.append(kind == "agent" ? "\(steps) steps" : "\(steps) tool calls") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
