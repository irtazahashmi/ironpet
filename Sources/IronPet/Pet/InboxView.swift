import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import SwiftUI

/// The Inbox section of the ironpet window: action items from meetings and things watchers and agents found. The user marks an
/// item done or removes it, and either takes it off the list. Clicking a row shows everything stored about it.
struct InboxView: View {
    @ObservedObject var tasks: TasksAPI
    let onOpenMeeting: (String) -> Void

    @State private var suggestionNav = ListNavigation<String>()
    @State private var search = ""

    enum Content: Equatable { case unavailable, empty, list }

    /// Items held in memory stay visible. With none, the unavailable state replaces "Nothing in the inbox", which would be wrong while the real list is out of reach.
    static func content(unavailable: Bool, isEmpty: Bool) -> Content { !isEmpty ? .list : unavailable ? .unavailable : .empty }

    var body: some View {
        ListScreen(title: IronPetSection.inbox.title, search: $search, detailOpen: suggestionNav.opened != nil, trailing: { EmptyView() }) {
            // The list stays in the hierarchy under the detail page so its scroll position survives opening an item.
            ZStack {
                listPage
                    .opacity(isDetailOpen ? 0 : 1)
                    .allowsHitTesting(!isDetailOpen)
                    .accessibilityHidden(isDetailOpen)
                if let id = suggestionNav.opened {
                    detailPage(id)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
                        .transition(.opacity)
                }
            }
        }
    }

    private var isDetailOpen: Bool { suggestionNav.opened != nil }

    @ViewBuilder private func detailPage(_ id: String) -> some View {
        if let item = tasks.suggestions.first(where: { $0.id == id }) {
            ListDetailPage(section: "Inbox", onBack: { suggestionNav.close() }) {
                Text(item.title).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Button("Done") { done(item); suggestionNav.close() }
                    Button("Remove") { remove(item); suggestionNav.close() }
                }
                .buttonStyle(.bordered)
                TaskDetailView(detail: TaskDetail(suggestion: item), onOpen: open(_:))
            }
        } else {
            // The item was marked done or removed elsewhere while it was open.
            Color.clear.onAppear { suggestionNav.close() }
        }
    }

    private var listPage: some View {
        VStack(spacing: 0) {
            if let reason = tasks.unavailable {
                DatabaseBanner(reason: reason)
            }
            let content = Self.content(unavailable: tasks.unavailable != nil, isEmpty: tasks.suggestions.isEmpty)
            if content == .unavailable {
                Spacer()
            } else if content == .empty {
                EmptyState(symbol: SharedSymbols.tasks, title: "Nothing in the inbox",
                           detail: "Action items from your meetings, and things \(petName) finds for you, wait here.")
            } else if rows.isEmpty {
                NoMatches()
            } else {
                ListScroll {
                    ForEach(rows) { item in
                        InboxRow(item: item, onDone: { done(item) }, onRemove: { remove(item) }, onOpen: open(_:),
                                 onShow: { suggestionNav.open(item.id) })
                    }
                }
            }
        }
    }

    private var rows: [TaskSuggestion] {
        tasks.suggestions.filter { ListSearch.matches(search, in: [$0.title, $0.notes]) }
    }

    private var petName: String { SettingsAPI.live.config.pet.name }

    private func done(_ item: TaskSuggestion) { try? tasks.done(item.id) }

    private func remove(_ item: TaskSuggestion) { try? tasks.remove(RemoveSuggestionRequest(id: item.id)) }

    private func open(_ link: TaskLink) {
        switch TaskLinkRow(link: link).action {
        case .openURL(let url): NSWorkspace.shared.open(url)
        case .openMeeting(let folder): onOpenMeeting(folder)
        case .none: break
        }
    }
}

// MARK: - Rows

private struct InboxRow: View {
    let item: TaskSuggestion
    let onDone: () -> Void
    let onRemove: () -> Void
    let onOpen: (TaskLink) -> Void
    let onShow: () -> Void

    var body: some View {
        ListRow(title: item.title, description: nil, onOpen: onShow,
                leading: { ListRowIcon(symbol: "lightbulb") },
                extra: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: item.source.symbol).font(.system(size: 10)).accessibilityHidden(true)
                            Text("\(item.originLabel), \(TaskTime.relative(item.created))")
                            if let due = item.due {
                                Text("·").accessibilityHidden(true)
                                Label("Due \(due)", systemImage: "calendar").labelStyle(DueLabelStyle())
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        HStack(spacing: 6) {
                            Button("Done", action: onDone).help("Mark this item done and take it off the list")
                            Button("Remove", action: onRemove).help("Take this item off the list")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                    }
                },
                trailing: { _ in
                    HStack(spacing: 2) {
                        ForEach(Array(item.links.enumerated()), id: \.offset) { _, link in
                            IconButton(symbol: link.symbol, help: link.help) { onOpen(link) }
                        }
                    }
                })
    }
}

// MARK: - Pieces

/// Icon and text on one baseline with a tight gap, for the metadata line.
private struct DueLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}
