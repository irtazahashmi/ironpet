import IronPetCore
import SwiftUI

/// The goals dashboard: active goals grouped by area, each with its progress and key results. The agent keeps the numbers;
/// this view only shows them.
struct TaskGoalsView: View {
    @ObservedObject var tasks: TasksAPI
    let search: String

    var body: some View {
        let active = tasks.goals.filter { $0.status == .active && ListSearch.matches(search, in: [$0.title, $0.why]) }
        if tasks.goals.allSatisfy({ $0.status != .active }) {
            EmptyState(symbol: "target", title: "No goals yet",
                       detail: "Tell \(SettingsAPI.live.config.pet.name) what you want to reach this year, and how you would measure it.")
        } else if active.isEmpty {
            NoMatches()
        } else {
            ListScroll {
                ForEach(groups(active), id: \.id) { group in
                    ListGroupTitle(group.title)
                    ForEach(group.goals) { goal in GoalCard(goal: goal, tasks: tasks) }
                }
            }
        }
    }

    /// Areas in title order, then goals with no area.
    /// Keyed by area id, so two areas cannot share an identity; "" is the goals with no area.
    private func groups(_ goals: [TaskGoal]) -> [(id: String, title: String, goals: [TaskGoal])] {
        var result = tasks.areas.compactMap { area -> (id: String, title: String, goals: [TaskGoal])? in
            let inArea = goals.filter { $0.area == area.id }
            return inArea.isEmpty ? nil : (area.id, area.title, inArea)
        }
        let loose = goals.filter { goal in goal.area.map { id in !tasks.areas.contains { $0.id == id } } ?? true }
        if !loose.isEmpty { result.append(("", "No area", loose)) }
        return result
    }
}

private struct GoalCard: View {
    let goal: TaskGoal
    @ObservedObject var tasks: TasksAPI

    var body: some View {
        let results = tasks.keyResults(of: goal.id)
        let projects = tasks.projects(serving: goal.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let progress = tasks.progress(of: goal.id) {
                    Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !goal.why.isEmpty { Text(goal.why).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let progress = tasks.progress(of: goal.id) {
                Gauge(value: progress) { Text("\(goal.title) progress") }
                    .gaugeStyle(.linearCapacity)
                    .labelsHidden()
            }
            ForEach(results) { result in
                HStack {
                    Text(result.metric).lineLimit(1)
                    Spacer()
                    Text("\(Self.number(result.current)) / \(Self.number(result.target))\(result.unit.map { " \($0)" } ?? "")")
                        .monospacedDigit()
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
            if results.isEmpty { Text("No key results yet").font(.caption).foregroundStyle(.orange) }
            if !projects.isEmpty {
                Text(projects.count == 1 ? "1 project" : "\(projects.count) projects").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
}
