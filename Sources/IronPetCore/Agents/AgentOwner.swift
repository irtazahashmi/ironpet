import Foundation

/// Who owns a chat thread, an agent session or an automation: an agent id. A missing or empty id means agent 1 (`agent_default`),
/// so a file or a row written before owners existed belongs to agent 1 without being rewritten.
package enum AgentOwner {
    /// Agent 1.
    package nonisolated static let defaultID = AgentID.default.rawValue

    /// The owner an optional id names: agent 1 when there is none.
    package nonisolated static func id(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return defaultID }
        return raw
    }

    /// The agent id a call names, checked against the agents on this install. Nil and empty are agent 1. An id no agent has is `notFound`.
    /// Without a registry (a host with no database) only agent 1 exists.
    @MainActor
    package static func resolve(_ raw: String?, registry: AgentRegistry?) throws -> String {
        let id = Self.id(raw)
        if let registry {
            guard registry.get(id) != nil else { throw APIError.notFound("no agent with id \"\(id)\"") }
        } else if id != defaultID {
            throw APIError.notFound("no agent with id \"\(id)\"")
        }
        return id
    }
}
