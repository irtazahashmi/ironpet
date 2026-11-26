import Foundation

/// Who a task is assigned to. A task has no assignee when the user does the work, and one agent id when an agent does. The id of agent 1
/// is `agent_default`, so "no assignee" and "agent 1" are different values.
package enum TaskAssignee {
    /// What a filter or a change sends for the user, besides null and an empty string.
    package nonisolated static let userValue = "user"
    /// What the Mac and the iPhone show for the user.
    package nonisolated static let userLabel = "You"

    /// The stored value: nil for null, blank and `user`, otherwise the trimmed agent id.
    package nonisolated static func normalize(_ raw: String?) -> String? {
        let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty || id == userValue ? nil : id
    }

    /// The choices for an assignee picker: the user first, then every agent by number. A task whose agent was deleted keeps its id as a
    /// choice, so the picker still shows the value the task has.
    package nonisolated static func choices(current: String?, agents: [AgentRecord]) -> [(id: String?, name: String)] {
        var list: [(id: String?, name: String)] = [(nil, userLabel)] + agents.sorted { $0.number < $1.number }.map { ($0.id, $0.name) }
        if let current, !agents.contains(where: { $0.id == current }) { list.append((current, current)) }
        return list
    }

    /// The agent's name, or "You". An id with no record (the agent was deleted) shows as the id.
    package nonisolated static func name(_ assignee: String?, agents: [AgentRecord]) -> String {
        guard let assignee else { return userLabel }
        return agents.first { $0.id == assignee }?.name ?? assignee
    }
}
