import Foundation
#if canImport(Combine)
import Combine
#endif

package enum AutomationApproval: String, Codable, Equatable {
    case pending, rejected
}

package struct AutomationRunInfo: Codable, Equatable {
    package init(date: Date, outcome: String, output: String) {
        self.date = date
        self.outcome = outcome
        self.output = output
    }

    package var date: Date
    /// `fired`, `ok`, `failed`, `baseline`, `skipped` or `waiting`.
    package var outcome: String
    package var output: String
}

/// What a client shows next to an automation: when it runs, how it last went, whether it waits for approval.
package struct AutomationStatus: Codable, Equatable {
    package init(
        id: String,
        trigger: String,
        nextRun: Date? = nil,
        lastRun: AutomationRunInfo? = nil,
        approval: AutomationApproval? = nil,
        stream: String? = nil,
        lastEvent: Date? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.nextRun = nextRun
        self.lastRun = lastRun
        self.approval = approval
        self.stream = stream
        self.lastEvent = lastEvent
    }

    package var id: String
    /// One line about the trigger, such as "daily at 09:00".
    package var trigger: String
    package var nextRun: Date?
    package var lastRun: AutomationRunInfo?
    package var approval: AutomationApproval?
    /// For a stream automation: `running`, `restarting` or `stopped`.
    package var stream: String?
    package var lastEvent: Date?
}

package struct CreateAutomationRequest: Codable, Equatable {
    package init(definition: String, by: String = "user", agentId: String? = nil) {
        self.definition = definition
        self.by = by
        self.agentId = agentId
    }

    /// The automation as a JSON object (name, trigger, action, presentation). A missing id is made from the name.
    package var definition: String
    package var by = "user"
    /// The agent that owns the automation. Nil keeps the `agentId` in `definition`, and without one the owner is agent 1.
    package var agentId: String?
}

/// `params` for the calls that list one agent's things. Nil is agent 1, as the Mac's window is.
package struct AgentScopeRequest: Codable, Equatable {
    package init(agentId: String? = nil) {
        self.agentId = agentId
    }

    package var agentId: String?
}

package struct UpdateAutomationRequest: Codable, Equatable {
    package init(id: String, changes: String, by: String = "user") {
        self.id = id
        self.changes = changes
        self.by = by
    }

    package var id: String
    /// A JSON object merged into the automation. A null value removes the key.
    package var changes: String
    package var by = "user"
}

/// Changes the time or the days of a daily automation. A nil field keeps its value.
package struct SetAutomationScheduleRequest: Codable, Equatable {
    package init(id: String, times: [String]? = nil, weekdays: [String]? = nil, everyDay: Bool = false) {
        self.id = id
        self.times = times
        self.weekdays = weekdays
        self.everyDay = everyDay
    }

    package var id: String
    package var times: [String]?
    package var weekdays: [String]?
    /// Runs every day: removes the weekday list. `weekdays` is ignored when this is set.
    package var everyDay = false
}

package struct AutomationHistoryRequest: Codable, Equatable {
    package init(id: String, limit: Int = 20) {
        self.id = id
        self.limit = limit
    }

    package var id: String
    package var limit = 20
}

package struct AutomationLogRequest: Codable, Equatable {
    package init(automation: String? = nil, limit: Int = 500, onlyProblems: Bool = false) {
        self.automation = automation
        self.limit = limit
        self.onlyProblems = onlyProblems
    }

    /// Only this automation's runs. Nil lists every automation.
    package var automation: String?
    package var limit = 500
    package var onlyProblems = false
}

package struct AutomationLogEntry: Codable, Equatable, Identifiable {
    package init(id: Int64, automation: String, date: Date, duration: TimeInterval, outcome: String, summary: String, detail: String) {
        self.id = id
        self.automation = automation
        self.date = date
        self.duration = duration
        self.outcome = outcome
        self.summary = summary
        self.detail = detail
    }

    package var id: Int64
    package var automation: String
    package var date: Date
    package var duration: TimeInterval
    package var outcome: String
    package var summary: String
    package var detail: String
}

package struct AutomationRunResult: Codable, Equatable {
    package init(id: String, status: String) {
        self.id = id
        self.status = status
    }

    package var id: String
    /// `started`, or `waiting for approval` when the user has not approved what it runs.
    package var status: String
}

/// Reminders, watchers and scheduled jobs: list, get, create, update, pause, resume, run, history, approve and reject.
@MainActor
package final class AutomationsAPI {
    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    private let service: AutomationService
    private var forwarding: [ChangeToken] = []

    package init(service: AutomationService) {
        self.service = service
        forwarding = [
            service.store.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    // MARK: Reading

    package var automations: [Automation] { service.store.automations }
    /// Why the file could not be read, when it could not.
    package var error: String? { service.store.error }
    /// The file the automations are saved in.
    package var file: URL { service.store.paths.file }

    /// Every automation, whoever owns it.
    package func list() -> [Automation] { automations }

    /// The automations this agent owns, plus the node-level ones, which belong to every agent. Nil is agent 1. An id no agent has is
    /// `notFound`.
    package func list(agentId: String?) throws -> [Automation] {
        let agent = try AgentOwner.resolve(agentId, registry: service.registry)
        return automations.filter { $0.isVisible(to: agent) }
    }

    package func get(_ id: String) throws -> Automation {
        guard let automation = automations.first(where: { $0.id == id }) else { throw APIError.notFound("no automation with id \"\(id)\"") }
        return automation
    }

    package func status(_ id: String) throws -> AutomationStatus {
        let a = try get(id)
        var status = AutomationStatus(id: id, trigger: service.describe(a.trigger))
        status.nextRun = a.enabled ? service.engine.nextRun(a) : nil
        status.lastRun = service.lastRun(id).map { AutomationRunInfo(date: $0.date, outcome: $0.outcome, output: $0.output) }
        if service.needsApproval(a) { status.approval = service.isRejected(a) ? .rejected : .pending }
        if a.trigger.type == "stream" {
            status.stream = service.engine.streams.status(id).rawValue
            status.lastEvent = service.engine.streams.lastEvent(id)
        }
        return status
    }

    package func history(_ request: AutomationHistoryRequest) throws -> [AutomationRunInfo] {
        let a = try get(request.id)
        return service.engine.state.history(a.id, limit: max(1, request.limit)).reversed()
            .map { AutomationRunInfo(date: $0.date, outcome: $0.outcome, output: $0.output) }
    }

    /// The automation's public `auto_<hex>` id.
    package func ref(_ id: String) -> String? { service.engine.state.records.ref(.auto, id) }

    /// One run by its row id, as `automations_history` lists it, with the automation it belongs to. Nil once it has been pruned.
    package func runRecord(_ key: String) -> [String: Any]? {
        guard let rowID = Int64(key), let found = service.engine.state.run(rowID) else { return nil }
        var out: [String: Any] = ["automation": found.automation, "time": AutomationClock.format(found.run.date),
                                  "outcome": found.run.outcome, "output": found.run.output]
        if let ref = service.engine.state.records.ref(.auto, found.automation) { out["automationRef"] = ref }
        return out
    }

    /// The command, script or prompt the user is asked to approve.
    package func approvalDetail(_ id: String) throws -> String { service.approvalDetail(try get(id)) }

    /// The automation as pretty JSON, for a hand edit.
    package func definition(_ id: String) throws -> String { service.json(for: try get(id)) }

    // MARK: Logs

    package var logsUnavailable: String? { service.engine.state.unavailable }
    package var logRetentionDays: Int { service.logRetentionDays() }

    package func logs(_ request: AutomationLogRequest = AutomationLogRequest()) -> [AutomationLogEntry] {
        let all = service.engine.state.logs(automation: request.automation, limit: request.limit)
        let kept = request.onlyProblems ? all.filter { ["failed", "skipped", "waiting"].contains($0.outcome) } : all
        return kept.map { AutomationLogEntry(id: $0.id, automation: $0.automation, date: $0.date, duration: $0.duration,
                                             outcome: $0.outcome, summary: $0.summary, detail: $0.detail) }
    }

    package func clearLogs(automation: String?) { service.engine.state.clearLogs(automation: automation) }

    // MARK: Changing

    @discardableResult
    package func create(_ request: CreateAutomationRequest) throws -> Automation {
        var definition = try Self.object(request.definition)
        if let agent = request.agentId { definition["agentId"] = agent }
        return try run { try service.create(definition, by: request.by) }
    }

    @discardableResult
    package func update(_ request: UpdateAutomationRequest) throws -> Automation {
        try run { try service.update(["id": request.id, "changes": try Self.object(request.changes)], by: request.by) }
    }

    /// Replaces an automation with a hand-edited JSON document. The user is the author, so no approval is asked.
    package func replace(id: String, definition: String) throws {
        if let problem = service.saveEdited(id: id, json: definition) { throw APIError.invalid(problem) }
    }

    package func setEnabled(_ id: String, _ enabled: Bool) throws {
        _ = try get(id)
        try run { try service.store.update(id) { $0.enabled = enabled } }
    }

    package func setSchedule(_ request: SetAutomationScheduleRequest) throws {
        _ = try get(request.id)
        try run {
            try service.store.update(request.id) {
                if let times = request.times { $0.trigger.times = times }
                if request.everyDay { $0.trigger.weekdays = nil } else if let weekdays = request.weekdays { $0.trigger.weekdays = weekdays }
            }
        }
    }

    package func delete(_ id: String) throws {
        let a = try get(id)
        try run { try service.store.replace(service.store.automations.filter { $0.id != a.id }) }
        service.engine.state.forget(a.id)
        service.dismissNotice(AutomationService.approvalID(a.id))
    }

    /// Runs it now, outside its schedule. A poll or script automation polls once.
    package func runNow(_ id: String) async throws -> AutomationRunResult {
        let a = try get(id)
        if a.trigger.type == "poll" || a.trigger.type == "script" {
            await service.engine.pollNow(a.id)
        } else {
            service.handle(.init(automations: [a], item: nil, agentWorking: false, manual: true, count: a.trigger.type == "stream" ? 1 : nil))
        }
        return AutomationRunResult(id: a.id, status: service.needsApproval(a) ? "waiting for approval" : "started")
    }

    /// Approves what the automation runs. Any client can do this, as the Approve button does.
    package func approve(_ id: String) throws {
        _ = try get(id)
        service.approve(id)
    }

    package func reject(_ id: String) throws {
        _ = try get(id)
        service.reject(id)
    }

    /// Asks about, or with auto-approve on approves, every enabled automation whose command is new.
    package func reviewApprovals() { service.reviewApprovals() }

    // MARK: JSON adapter

    /// The MCP tools and the `IronPet automations` CLI call this with loose JSON arguments. Their result shapes are part of the
    /// tool contract, so the dictionaries `AutomationService` builds are kept.
    /// `agent` is the agent the call comes from: `list` shows its automations and `create` makes the new one its own.
    package func callJSON(_ op: String, _ args: [String: Any], by: String, agent: String? = nil) async -> Result<Any, AutomationError> {
        await service.call(op, args, by: by, agent: agent)
    }

    /// The agent that owns this automation, for an MCP caller that is an automation's own session. Nil for a node-level or unknown one.
    package func owner(of automation: String) -> String? { automations.first { $0.id == automation }?.ownerAgentID }

    // MARK: Helpers

    private static func object(_ json: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw APIError.invalid("That is not a JSON object.")
        }
        return object
    }

    private func run<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as AutomationError {
            throw error.message.hasPrefix("no automation") || error.message.hasPrefix("no agent") ? APIError.notFound(error.message) : APIError.invalid(error.message)
        } catch {
            throw APIError.wrap(error)
        }
    }
}

#if canImport(Combine)

extension AutomationsAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
