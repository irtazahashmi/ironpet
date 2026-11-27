import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import IronPetKit
import SwiftUI

/// The Inbox section of the ironpet window: action items from meetings, chats, the screen and the watchers and agents that found them,
/// in one group for each place they came from, newest first. A row is one line: the Done circle, the title, when it arrived and, when
/// the item has a link, an Open button. Clicking a row opens its page. Items resolved today are listed at the end with the reason.
struct InboxView: View {
    @ObservedObject var tasks: TasksAPI
    let onOpenMeeting: (String) -> Void
    var onOpenChat: (String) -> Void = { _ in }

    @State private var nav = ListNavigation<String>()
    @State private var search = ""
    @State private var resolvedOpen = true
    @State private var resolvedAll = false

    enum Content: Equatable { case unavailable, empty, list }

    /// Items held in memory stay visible. With none, the unavailable state replaces "Nothing in the inbox", which would be wrong while the real list is out of reach.
    static func content(unavailable: Bool, isEmpty: Bool) -> Content { !isEmpty ? .list : unavailable ? .unavailable : .empty }

    /// Resolved rows shown before "Show more".
    static let resolvedPreview = 8

    /// The key an open item has in the navigation.
    static func openKey(_ item: TaskSuggestion) -> String { "open:" + item.id }

    /// The key a resolved item has: a later item can reuse the id of a resolved one, so the time is part of it.
    static func resolvedKey(_ record: ResolvedSuggestion) -> String { "resolved:\(record.id):\(record.resolved.timeIntervalSince1970)" }

    var body: some View {
        ListScreen(title: IronPetSection.inbox.title, search: $search, detailOpen: nav.opened != nil,
                   titleView: nav.opened == nil ? AnyView(header) : nil, trailing: { EmptyView() }) {
            // The list stays in the hierarchy under the detail page so its scroll position survives opening an item.
            ZStack {
                listPage
                    .opacity(isDetailOpen ? 0 : 1)
                    .allowsHitTesting(!isDetailOpen)
                    .accessibilityHidden(isDetailOpen)
                if let key = nav.opened {
                    detailPage(key)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
                        .transition(.opacity)
                }
            }
        }
    }

    private var isDetailOpen: Bool { nav.opened != nil }

    private var header: some View {
        HStack(spacing: 8) {
            Text(IronPetSection.inbox.title).font(.system(size: 15, weight: .semibold))
            if !tasks.suggestions.isEmpty {
                Text("\(tasks.suggestions.count) open").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    // MARK: Item page

    @ViewBuilder private func detailPage(_ key: String) -> some View {
        if let item = tasks.suggestions.first(where: { Self.openKey($0) == key }) {
            ListDetailPage(section: "Inbox", onBack: { nav.close() }) {
                InboxItemHeader(item: item, onDone: { done(item); nav.close() }, onRemove: { remove(item); nav.close() },
                                onOpenURL: open(_:), onOpenChat: onOpenChat)
                if !item.shownNotes.isEmpty {
                    CardSection(title: "Notes") {
                        MarkdownView(text: item.shownNotes, size: 13).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                InboxSourcesSection(rows: item.sourceRows, onOpenURL: open(_:), onOpenChat: onOpenChat, onOpenMeeting: onOpenMeeting)
            }
        } else if let record = tasks.resolvedToday().first(where: { Self.resolvedKey($0) == key }) {
            ListDetailPage(section: "Inbox", onBack: { nav.close() }) {
                InboxResolvedHeader(record: record, onOpenChat: onOpenChat)
                CardSection(title: "Evidence") {
                    Text(record.reason).font(.system(size: 13)).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                InboxSourcesSection(rows: record.sourceRows, onOpenURL: open(_:), onOpenChat: onOpenChat, onOpenMeeting: onOpenMeeting)
            }
        } else {
            // The item was marked done or removed elsewhere while it was open.
            Color.clear.onAppear { nav.close() }
        }
    }

    // MARK: List

    private var listPage: some View {
        VStack(spacing: 0) {
            if let reason = tasks.unavailable {
                DatabaseBanner(reason: reason)
            }
            let content = Self.content(unavailable: tasks.unavailable != nil, isEmpty: tasks.suggestions.isEmpty && resolved.isEmpty)
            if content == .unavailable {
                Spacer()
            } else if content == .empty {
                EmptyState(symbol: SharedSymbols.tasks, title: "Nothing in the inbox",
                           detail: "Action items from your meetings, and things \(petName) finds for you, wait here.")
            } else if groups.isEmpty, shownResolved.isEmpty {
                NoMatches()
            } else {
                ListScroll {
                    ForEach(groups, id: \.kind) { group in
                        InboxGroupHeader(symbol: group.symbol, title: group.title, count: group.items.count)
                        ForEach(group.items) { item in
                            InboxRow(item: item, onDone: { done(item) }, onRemove: { remove(item) }, onOpenURL: open(_:),
                                     onShow: { nav.open(Self.openKey(item)) })
                        }
                    }
                    if !shownResolved.isEmpty { resolvedSection }
                }
            }
        }
    }

    @ViewBuilder private var resolvedSection: some View {
        Button { resolvedOpen.toggle() } label: {
            InboxGroupHeader(symbol: resolvedOpen ? "chevron.down" : "chevron.right", title: "Resolved today", count: shownResolved.count)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel("Resolved today, \(shownResolved.count)")
        .accessibilityHint(resolvedOpen ? "Hides the resolved items" : "Shows the resolved items")
        if resolvedOpen {
            let visible = resolvedAll ? shownResolved : Array(shownResolved.prefix(Self.resolvedPreview))
            ForEach(visible, id: \.resolved) { record in
                InboxResolvedRow(record: record, onShow: { nav.open(Self.resolvedKey(record)) })
            }
            if shownResolved.count > visible.count {
                Button("Show \(shownResolved.count - visible.count) more") { resolvedAll = true }
                    .buttonStyle(.link).font(.system(size: 12.5)).padding(.horizontal, 2)
            }
        }
    }

    private var groups: [InboxGroup<TaskSuggestion>] {
        TaskSuggestion.groups(tasks.suggestions.filter { ListSearch.matches(search, in: [$0.title, $0.notes]) })
    }

    private var resolved: [ResolvedSuggestion] { tasks.resolvedToday() }

    private var shownResolved: [ResolvedSuggestion] {
        resolved.filter { ListSearch.matches(search, in: [$0.title, $0.reason]) }
    }

    private var petName: String { SettingsAPI.live.config.pet.name }

    private func done(_ item: TaskSuggestion) { try? tasks.done(item.id) }

    private func remove(_ item: TaskSuggestion) { try? tasks.remove(RemoveSuggestionRequest(id: item.id)) }

    private func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

// MARK: - Time

enum InboxTime {
    /// When an item arrived: "27 Nov, 15:04" in the user's language and clock.
    static func arrived(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated).hour().minute()) }

    /// When an item was resolved today: "16:31".
    static func resolved(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

// MARK: - Rows

private struct InboxGroupHeader: View {
    let symbol: String
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10.5)).accessibilityHidden(true)
            Text(title.uppercased()).tracking(0.6)
            Text("\(count)").foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .contentShape(Rectangle())
    }
}

/// One line per item. The Done circle takes the item off the list, Open shows only for an item with a link, and Remove shows when the
/// pointer is over the row.
private struct InboxRow: View {
    let item: TaskSuggestion
    let onDone: () -> Void
    let onRemove: () -> Void
    let onOpenURL: (URL) -> Void
    let onShow: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onDone) {
                Image(systemName: "circle").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Mark this item done and take it off the list")
            .accessibilityLabel("Done")
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if let others = item.otherSourcesLabel {
                Text(others).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if let due = item.due {
                Text("Due \(due)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(TaskTime.relative(item.created)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let url = item.openURL {
                    Button { onOpenURL(url) } label: {
                        HStack(spacing: 3) {
                            Text("Open")
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Open \(url.host ?? "the link")")
                } else {
                    Color.clear
                }
            }
            .frame(width: 66, alignment: .trailing)
            Button(action: onRemove) {
                Image(systemName: SharedSymbols.removeAttachment).font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove")
            .accessibilityLabel("Remove")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onShow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
        .accessibilityAction(named: "Show details", onShow)
    }
}

private struct InboxResolvedRow: View {
    let record: ResolvedSuggestion
    let onShow: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green).frame(width: 16)
                .accessibilityHidden(true)
            Text(record.title).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(record.reason).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(InboxTime.resolved(record.resolved)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onShow)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.title), resolved by \(record.resolverLabel). \(record.reason)")
        .accessibilityAction(named: "Show details", onShow)
    }
}

// MARK: - Item page

/// The header card of an open item: the title, the line that says where it came from, and Done, Remove and Open.
private struct InboxItemHeader: View {
    let item: TaskSuggestion
    let onDone: () -> Void
    let onRemove: () -> Void
    let onOpenURL: (URL) -> Void
    let onOpenChat: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
            InboxOriginText(line: item.originLine, time: InboxTime.arrived(item.created), onOpenChat: onOpenChat)
            if let due = item.due, !due.isEmpty {
                Label("Due \(due)", systemImage: "calendar").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Done", action: onDone).help("Mark this item done and take it off the list")
                Button("Remove", action: onRemove).help("Take this item off the list")
                if let url = item.openURL {
                    Button { onOpenURL(url) } label: {
                        HStack(spacing: 3) {
                            Text("Open")
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .help("Open \(url.host ?? "the link")")
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardMaterial()
    }
}

/// The header card of a resolved item: who resolved it and when, the title, and where it came from.
private struct InboxResolvedHeader: View {
    let record: ResolvedSuggestion
    let onOpenChat: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(record.statusLine(time: InboxTime.resolved(record.resolved)), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.green)
            Text(record.title).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
            InboxOriginText(line: record.originLine, time: InboxTime.arrived(record.created), onOpenChat: onOpenChat)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardMaterial()
    }
}

/// "Found by the inbox scan in a chat between the user and Bunny, 27 Nov, 15:04" with the word chat as a link that opens the thread.
private struct InboxOriginText: View {
    let line: InboxOriginLine
    let time: String
    let onOpenChat: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: line.symbol).font(.system(size: 11)).accessibilityHidden(true)
            Text(InboxChatLink.text(line, time: time))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard let thread = InboxChatLink.thread(from: url) else { return .discarded }
                    onOpenChat(thread)
                    return .handled
                })
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row for each place the item came from: its name on the left and, on the right, the link that opens the chat, the meeting or the page.
private struct InboxSourcesSection: View {
    let rows: [InboxSourceRow]
    let onOpenURL: (URL) -> Void
    let onOpenChat: (String) -> Void
    let onOpenMeeting: (String) -> Void

    var body: some View {
        if !rows.isEmpty {
            CardSection(title: "Sources") {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    HStack(spacing: 8) {
                        Label { Text(row.title) } icon: { Image(systemName: row.symbol).frame(width: 16) }
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if let title = row.actionTitle {
                            Button(title) { perform(row.action) }
                                .buttonStyle(.link)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                }
            }
        }
    }

    private func perform(_ action: InboxSourceRow.Action) {
        switch action {
        case .showChat(let thread): onOpenChat(thread)
        case .openURL(let url): onOpenURL(url)
        case .openMeeting(let folder): onOpenMeeting(folder)
        case .none: break
        }
    }
}
