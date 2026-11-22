import Foundation

/// Permission requests from runs that have no chat: background jobs and the `new`, `own` and `fork` sessions of an automation.
/// A request becomes an alert in the alerts list, and `onRaised` listeners (the Mac's bubble and notification, Telegram) show it
/// with the agent's own options. The run waits. An answer goes back as the chosen option id. With no answer after `timeout`
/// seconds, the agent gets its `reject_once` option and the run records "permission timed out: <tool>".
@MainActor
package final class BackgroundPermissions {
    package struct Request: Identifiable, Equatable {
        package let id: UUID
        /// The id of the job or automation run that asked. A run's end resolves its requests by this.
        package let owner: String
        /// The job or automation that asked, such as `Job "Fix the build"`.
        package let source: String
        /// The tool the agent wants to use, such as `Bash` or `mcp__github__create_issue`.
        package let tool: String
        package let title: String
        package let detail: String
        package let options: [PermissionOption]
        package let date: Date

        /// The line a client shows: who wants what.
        package var heading: String { "\(source) wants to: \(title)" }
    }

    package enum Outcome: Equatable { case answered(allowed: Bool), timedOut, ended }

    package init(signals: SignalStore? = nil, timeout: @escaping () -> TimeInterval = { 600 }) {
        self.signals = signals
        self.timeout = timeout
    }

    /// Fires before `pending` changes.
    package let changes = ChangeSignal()
    package private(set) var pending: [Request] = [] { willSet { changes.send() } }
    package weak var signals: SignalStore?
    /// Seconds a request waits for an answer. The app reads `jobs.permissionTimeoutMinutes`.
    package var timeout: () -> TimeInterval

    private struct Waiting {
        let request: Request
        let respond: (ApprovalDecision) -> Void
        let timedOut: (String) -> Void
        var timer: Task<Void, Never>?
    }

    private var waiting: [UUID: Waiting] = [:]
    private var raisedListeners: [UUID: (Request) -> Void] = [:]
    private var resolvedListeners: [UUID: (UUID, Outcome) -> Void] = [:]

    package static func alertID(_ id: UUID) -> String { "permission:\(id.uuidString)" }

    /// Hears each request as it is raised and as it is resolved, by an answer, a timeout, or the end of its run.
    @discardableResult
    package func observe(raised: @escaping (Request) -> Void, resolved: @escaping (UUID, Outcome) -> Void) -> () -> Void {
        let key = UUID()
        raisedListeners[key] = raised
        resolvedListeners[key] = resolved
        return { [weak self] in
            self?.raisedListeners[key] = nil
            self?.resolvedListeners[key] = nil
        }
    }

    /// Raises the alert and holds `respond` until someone answers. `timedOut` gets the line for the run's history.
    @discardableResult
    package func ask(owner: String, source: String, call: ACPToolCall, respond: @escaping (ApprovalDecision) -> Void,
                     timedOut: @escaping (String) -> Void) -> UUID {
        let card = ApprovalRules.card(for: call)
        let tool = call.mcp?.tool ?? call.toolName ?? (call.title.isEmpty ? call.kind : call.title)
        let request = Request(id: UUID(), owner: owner, source: source, tool: tool, title: card.title, detail: card.detail,
                              options: call.permissionOptions, date: Date())
        var entry = Waiting(request: request, respond: respond, timedOut: timedOut)
        let seconds = max(1, timeout())
        entry.timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.expire(request.id)
        }
        waiting[request.id] = entry
        pending.append(request)
        signals?.add(Signal(id: Self.alertID(request.id), title: request.heading, subtitle: String(request.detail.prefix(200)), url: nil,
                            label: "Permission", symbol: "hand.raised.fill", mood: .needsInput, detail: request.detail), notify: false)
        for listener in raisedListeners.values { listener(request) }
        return request.id
    }

    /// The user picked one of the agent's options. False when the request is gone or the agent did not offer that option.
    @discardableResult
    package func answer(_ id: UUID, optionID: String) -> Bool {
        guard let option = waiting[id]?.request.options.first(where: { $0.id == optionID }) else { return false }
        return finish(id, decision: .choose(option), outcome: .answered(allowed: option.allows))
    }

    /// An answer from a client with only allow and deny: the agent's `allow_once` or `reject_once` option, or the first of that side.
    @discardableResult
    package func answer(_ id: UUID, allow: Bool) -> Bool {
        guard let entry = waiting[id] else { return false }
        let options = entry.request.options
        let once = allow ? "allow_once" : "reject_once"
        let option = options.first { $0.kind == once } ?? options.first { allow ? $0.allows : $0.kind.hasPrefix("reject") }
        let decision = option.map(ApprovalDecision.choose) ?? (allow ? .allow : .deny())
        return finish(id, decision: decision, outcome: .answered(allowed: allow))
    }

    package func has(_ id: UUID) -> Bool { waiting[id] != nil }

    /// The alert row was dismissed: that is a refusal.
    @discardableResult
    package func dismissAlert(_ alertID: String) -> Bool {
        guard let id = waiting.keys.first(where: { Self.alertID($0) == alertID }) else { return false }
        return answer(id, allow: false)
    }

    /// The run ended or was stopped. The agent is told no and the alert goes away.
    package func end(owner: String) {
        for id in waiting.values.filter({ $0.request.owner == owner }).map(\.request.id) {
            finish(id, decision: .deny("The run ended"), outcome: .ended)
        }
    }

    /// Raises a run's open requests again, say after their bubble was closed without an answer.
    package func reshow(owner: String) {
        for request in pending where request.owner == owner { for listener in raisedListeners.values { listener(request) } }
    }

    package func pending(owner: String) -> [Request] { pending.filter { $0.owner == owner } }

    package func endAll() {
        for id in Array(waiting.keys) { finish(id, decision: .deny("ironpet quit"), outcome: .ended) }
    }

    private func expire(_ id: UUID) {
        guard let entry = waiting[id] else { return }
        let options = entry.request.options
        let option = options.first { $0.kind == "reject_once" } ?? options.first { $0.kind.hasPrefix("reject") }
        let decision = option.map(ApprovalDecision.choose) ?? .deny("Nobody answered in time")
        let line = "permission timed out: \(entry.request.tool)"
        entry.timedOut(line)
        ChatLog.note("\(entry.request.source): \(line)")
        finish(id, decision: decision, outcome: .timedOut)
    }

    @discardableResult
    private func finish(_ id: UUID, decision: ApprovalDecision, outcome: Outcome) -> Bool {
        guard let entry = waiting.removeValue(forKey: id) else { return false }
        entry.timer?.cancel()
        pending.removeAll { $0.id == id }
        signals?.removeAll { $0.id == Self.alertID(id) }
        entry.respond(decision)
        for listener in resolvedListeners.values { listener(id, outcome) }
        return true
    }
}
