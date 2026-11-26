import Foundation
#if canImport(Combine)
import Combine
#endif

/// `GET /v1/agent-records`.
package struct AgentRecordListResponse: Codable, Equatable {
    package var agents: [AgentRecord]

    package init(agents: [AgentRecord]) {
        self.agents = agents
    }
}

/// `agent.create`. Only `name` and `agentCli` are required.
package struct CreateAgentRequest: Codable, Equatable {
    package init(name: String, agentCli: String, pet: String? = nil, model: String? = nil, instructions: String? = nil) {
        self.name = name
        self.agentCli = agentCli
        self.pet = pet
        self.model = model
        self.instructions = instructions
    }

    package var name: String
    package var agentCli: String
    package var pet: String?
    package var model: String?
    package var instructions: String?
}

/// `agent.update`. A field left out stays as it is. An empty `pet` or `model` clears it, back to the bundled Ghost or the CLI's own
/// default model. `enabled: false` stops the agent's process and hides its pet, and `true` starts them again.
package struct UpdateAgentRequest: Codable, Equatable {
    package init(id: String, name: String? = nil, pet: String? = nil, agentCli: String? = nil, model: String? = nil, instructions: String? = nil,
                 enabled: Bool? = nil) {
        self.id = id
        self.name = name
        self.pet = pet
        self.agentCli = agentCli
        self.model = model
        self.instructions = instructions
        self.enabled = enabled
    }

    package var id: String
    package var name: String?
    package var pet: String?
    package var agentCli: String?
    package var model: String?
    package var instructions: String?
    package var enabled: Bool?
}

/// The agents ironpet knows, as records: name, pet, agent CLI, model, instructions and tool permissions. `AgentsAPI` is a different
/// thing, the coding-agent sessions Ghost watches, and keeps its own methods.
///
/// Settings read and write agent 1 through this API. The pet's name and sprite still live in `config.json`, and this API copies a
/// change of either onto agent 1 so the record never disagrees with what the user sees.
@MainActor
package final class AgentRecordsAPI {
    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    package let registry: AgentRegistry
    private var forwarding: [ChangeToken] = []

    package init(registry: AgentRegistry) {
        self.registry = registry
        forwarding = [registry.changes.observe { [weak self] in self?.changes.send() }]
    }

    package func list() -> [AgentRecord] { registry.list() }

    package func get(_ id: String) throws -> AgentRecord {
        guard let record = registry.get(id) else { throw APIError.notFound("no agent with id \"\(id)\"") }
        return record
    }

    /// The agent the chat runs on, agent 1.
    package var chatAgent: AgentRecord? { registry.chatAgent }

    /// Changes an agent. Settings use it.
    @discardableResult
    package func update(_ id: String, _ patch: AgentRecordPatch) throws -> AgentRecord { try registry.update(id, patch) }

    /// How many enabled automations an agent owns. Set by `IronPetAPI`. Deleting an agent that owns any is refused.
    package var ownedEnabledAutomations: (String) -> Int = { _ in 0 }

    /// Adds an agent. It starts enabled, so the supervisor starts its process and the app shows its pet.
    @discardableResult
    package func create(_ request: CreateAgentRequest) throws -> AgentRecord {
        try registry.create(name: request.name, pet: request.pet.flatMap { $0.isEmpty ? nil : $0 }, agentCli: request.agentCli,
                            model: request.model.flatMap { $0.isEmpty ? nil : $0 }, instructions: request.instructions ?? "")
    }

    /// Changes the fields a request names.
    @discardableResult
    package func update(_ request: UpdateAgentRequest) throws -> AgentRecord {
        if let name = request.name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw APIError.invalid("an agent needs a name") }
        if let cli = request.agentCli, AgentCatalog.agent(id: cli) == nil { throw APIError.invalid("unknown agent CLI \"\(cli)\"") }
        let patch = AgentRecordPatch(name: request.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                                     pet: request.pet.map { $0.isEmpty ? nil : $0 }, agentCli: request.agentCli,
                                     model: request.model.map { $0.isEmpty ? nil : $0 }, instructions: request.instructions, enabled: request.enabled)
        return try registry.update(request.id, patch)
    }

    /// Deletes an agent's record. Its threads, sessions and automations stay on disk and nothing lists them. The call is refused while the
    /// agent owns an enabled automation, so a schedule is never left running for an agent that no longer exists: disable or delete the
    /// automation first. Agent 1 cannot be deleted.
    package func delete(_ id: String) throws {
        let record = try get(id)
        if record.id != AgentRegistry.chatAgentID {
            let owned = ownedEnabledAutomations(record.id)
            guard owned == 0 else { throw APIError.conflict("\(record.name) owns \(owned) enabled automation\(owned == 1 ? "" : "s"). Disable or delete \(owned == 1 ? "it" : "them") first.") }
        }
        try registry.delete(record.id)
    }

    /// Copies the pet's name and sprite from the settings onto agent 1 when they differ.
    package func mirror(pet: Config.Pet) {
        guard let agent = chatAgent, agent.name != pet.name || agent.pet != pet.sprite else { return }
        _ = try? registry.update(agent.id, AgentRecordPatch(name: pet.name, pet: .some(pet.sprite)))
    }
}

#if canImport(Combine)

extension AgentRecordsAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
