import Foundation

/// One pet on screen: the agent it belongs to, its name, its sprite sheet, and its place among the pets.
package struct PetSlot: Equatable, Sendable {
    package var agentID: String
    package var name: String
    /// Path to the sprite sheet. Nil is the bundled Ghost, or the sheet agent 1 uses.
    package var sprite: String?
    /// 0 for the first pet, 1 for the next. Pets of several agents stand side by side, so a second pet does not cover the first.
    package var index: Int

    /// How far left of its default place a pet stands, in points, so pets do not overlap before the user drags them.
    package var offsetX: Double { Double(index) * AgentPetSet.spacing }
}

/// Which pets are on screen: one for each enabled agent, in agent order. The Mac app diffs this against the pets it shows, so enabling an
/// agent adds a pet, disabling one removes it, and a disabled agent's history is not part of it.
package enum AgentPetSet {
    /// Space between two pets at first launch. A pet is 0.6 of a 192-point cell wide, so this leaves a small gap.
    package static let spacing: Double = 120

    package static func slots(for records: [AgentRecord]) -> [PetSlot] {
        records.filter(\.enabled).sorted { $0.number < $1.number }.enumerated().map { index, record in
            PetSlot(agentID: record.id, name: record.name, sprite: record.pet, index: index)
        }
    }

    /// What a click on an agent's pet opens: that agent's chat. Nil for an agent that has no pet on screen.
    package static func chatTarget(clicked agentID: String, in slots: [PetSlot]) -> String? {
        slots.contains { $0.agentID == agentID } ? agentID : nil
    }
}

/// The agent switcher in a chat window: the enabled agents, which one this window shows, and where choosing another goes.
package struct AgentSwitcher: Equatable, Sendable {
    package struct Choice: Equatable, Sendable, Identifiable {
        package var id: String
        package var name: String
        package var isCurrent: Bool
    }

    package let choices: [Choice]

    package init(records: [AgentRecord], current: String) {
        choices = records.filter(\.enabled).sorted { $0.number < $1.number }.map { Choice(id: $0.id, name: $0.name, isCurrent: $0.id == current) }
    }

    /// The switcher only shows when there is more than one agent to switch between.
    package var isVisible: Bool { choices.count > 1 }

    /// The agent whose chat opens when the user picks `id`. Nil when it is the chat already shown, or not an enabled agent.
    package func target(picking id: String) -> String? {
        guard let choice = choices.first(where: { $0.id == id }), !choice.isCurrent else { return nil }
        return choice.id
    }
}
