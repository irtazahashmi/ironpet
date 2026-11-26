import IronPetCore
import SwiftUI

/// The GTD projects with their next actions. An active project with none is stalled, and the row says so, since every active
/// project needs a next step. The agent creates and changes projects; clicking a row opens its next action.
struct TaskProjectsView: View {
    @ObservedObject var tasks: TasksAPI
    /// The page's search text, matched against the title, outcome and area.
    let search: String
    let onOpenTask: (String) -> Void

    var body: some View {
        let now = Date()
        let shown = tasks.projects.filter { ListSearch.matches(search, in: [$0.title, $0.outcome, $0.area ?? ""]) }
        let active = shown.filter { $0.status == .active }
        let someday = shown.filter { $0.status == .someday }
        if tasks.projects.allSatisfy({ $0.status == .done }) {
            EmptyState(symbol: "folder", title: "No projects yet",
                       detail: "Ask \(SettingsAPI.live.config.pet.name) to start a project, such as \"Launch the new site\".")
        } else if active.isEmpty && someday.isEmpty {
            NoMatches()
        } else {
            ListScroll {
                if !active.isEmpty {
                    ListGroupTitle(TaskProject.Status.active.title)
                    ForEach(active) { row($0, now: now) }
                }
                if !someday.isEmpty {
                    ListGroupTitle(TaskProject.Status.someday.title)
                    ForEach(someday) { row($0, now: now) }
                }
            }
        }
    }

    private func row(_ project: TaskProject, now: Date) -> some View {
        let next = tasks.nextActions(of: project.id, now: now)
        let stalled = project.status == .active && next.isEmpty
        return ListRow(title: project.title, description: project.outcome.isEmpty ? nil : project.outcome,
                       onOpen: next.first.map { first in { onOpenTask(first.id) } },
                       leading: { ListRowIcon(symbol: stalled ? "exclamationmark.triangle" : "folder") },
                       extra: {
                           VStack(alignment: .leading, spacing: 2) {
                               if let first = next.first {
                                   Text("Next: \(first.title)").lineLimit(1)
                               } else if stalled {
                                   Text("No next action").foregroundStyle(.orange)
                               }
                               let details = [project.area, next.count > 1 ? "\(next.count) next actions" : nil,
                                              project.isDueForReview(now: now) ? "Due for review" : nil].compactMap { $0 }
                               if !details.isEmpty { Text(details.joined(separator: " · ")).lineLimit(1) }
                           }
                           .font(.caption)
                           .foregroundStyle(.secondary)
                       },
                       trailing: { _ in EmptyView() })
            .accessibilityHint(next.isEmpty ? (stalled ? "This project has no next action" : "") : "Opens the next action")
    }
}
