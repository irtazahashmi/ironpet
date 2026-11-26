import Foundation
import IronPetKit

/// Encodes a phase 4 `IronPetKit` value the way the phone decodes it: snake_case keys the type names, ISO 8601 dates.
package enum RemoteWire {
    package static func object<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? WireJSON.makeEncoder().encode(value),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }

    package static func array<T: Encodable>(_ values: [T]) -> [[String: Any]] { values.map(object) }
}

/// The automation routes, as calls on `IronPetAPI.automations`. The device is the author (`remote:<device id>`), so an automation it
/// creates, or one whose command, script or prompt it changes, waits for Approve on the Mac. Nothing here approves or rejects.
@MainActor
package struct RemoteAutomations {
    package init(api: IronPetAPI, device: String) {
        self.api = api
        self.device = device
    }

    package let api: IronPetAPI
    /// The device that calls.
    package let device: String

    private var by: String { "remote:\(device)" }
    private var automations: AutomationsAPI { api.automations }

    private func dto(_ a: Automation, detail: Bool = false) -> RemoteAutomation {
        let status = (try? automations.status(a.id)) ?? AutomationStatus(id: a.id, trigger: "")
        var item = RemoteAutomation(id: a.id, name: a.name, enabled: a.enabled, trigger: status.trigger, triggerType: a.trigger.type,
                                    action: a.action.type, createdBy: a.createdBy, nextRun: status.nextRun,
                                    lastRun: status.lastRun.map { RemoteAutomationRun(date: $0.date, outcome: $0.outcome, output: $0.output) },
                                    approval: status.approval?.rawValue, stream: status.stream, lastEvent: status.lastEvent)
        if detail {
            if status.approval != nil { item.approvalDetail = try? automations.approvalDetail(a.id) }
            item.definition = try? automations.definition(a.id)
        }
        return item
    }

    package func list() -> [String: Any] { ["automations": RemoteWire.array(automations.list().map { dto($0) })] }

    /// The automations one agent owns, plus the node-level ones. Nil is agent 1.
    package func list(agentId: String?) throws -> [String: Any] {
        ["automations": RemoteWire.array(try automations.list(agentId: agentId).map { dto($0) })]
    }

    package func get(_ id: String) throws -> [String: Any] { RemoteWire.object(dto(try automations.get(id), detail: true)) }

    package func history(_ id: String, query: [String: [String]]) throws -> [String: Any] {
        let limit = min(100, max(1, query["limit"]?.first.flatMap(Int.init) ?? 20))
        let runs = try automations.history(AutomationHistoryRequest(id: id, limit: limit))
        return ["history": RemoteWire.array(runs.map { RemoteAutomationRun(date: $0.date, outcome: $0.outcome, output: $0.output) })]
    }

    /// The execution log lines of one automation, newest first, at most 200.
    package func log(_ id: String) throws -> [String: Any] {
        _ = try automations.get(id)
        let entries = automations.logs(AutomationLogRequest(automation: id, limit: 200))
        return ["log": RemoteWire.array(entries.map {
            RemoteAutomationLogEntry(id: Int($0.id), automation: $0.automation, date: $0.date, duration: $0.duration, outcome: $0.outcome,
                                     summary: $0.summary, detail: $0.detail)
        })]
    }

    package func pause(_ id: String) throws -> [String: Any] { try setEnabled(id, false) }

    package func resume(_ id: String) throws -> [String: Any] { try setEnabled(id, true) }

    private func setEnabled(_ id: String, _ enabled: Bool) throws -> [String: Any] {
        try automations.setEnabled(id, enabled)
        return RemoteWire.object(dto(try automations.get(id)))
    }

    package func runNow(_ id: String) async throws -> [String: Any] {
        let result = try await automations.runNow(id)
        return RemoteWire.object(RemoteAutomationRunResult(id: result.id, status: result.status))
    }

    package func delete(_ id: String) throws -> [String: Any] {
        try automations.delete(id)
        return ["deleted": id]
    }

    /// The body is the automation: name, trigger, action. The author is always this device, whatever the body says.
    package func create(_ args: [String: Any]) throws -> [String: Any] {
        let created = try automations.create(CreateAutomationRequest(definition: try Self.json(args), by: by))
        return RemoteWire.object(dto(created, detail: true))
    }

    /// The body is merged into the automation. Changing only timing or text keeps its author, so a user's automation stays approved.
    /// Changing what it runs makes this device the author, and the Mac asks for Approve again.
    package func update(_ id: String, _ args: [String: Any]) throws -> [String: Any] {
        var changes = args
        changes["id"] = nil
        changes["createdBy"] = nil
        let updated = try automations.update(UpdateAutomationRequest(id: id, changes: try Self.json(changes), by: by))
        return RemoteWire.object(dto(updated, detail: true))
    }

    /// "New automation…": the text goes to the chat with the instructions the Mac's own box adds, and the agent builds it.
    package func request(_ args: [String: Any]) async throws -> [String: Any] {
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RemoteFailure.invalid("text is empty") }
        guard text.count <= 4000 else { throw RemoteFailure.invalid("text is longer than 4000 characters") }
        let result = try await api.chat.send(SendChatRequest(text: AutomationAgentPrompts.newAutomation(text), origin: ChatOrigin.ios(device: device)))
        return ["outcome": result.outcome.rawValue]
    }

    private static func json(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw RemoteFailure.invalid("the body must be a JSON object")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
