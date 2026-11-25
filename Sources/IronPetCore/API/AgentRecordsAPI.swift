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

    /// Changes an agent. Settings use it; no RPC method or MCP tool writes an agent yet.
    @discardableResult
    package func update(_ id: String, _ patch: AgentRecordPatch) throws -> AgentRecord { try registry.update(id, patch) }

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
