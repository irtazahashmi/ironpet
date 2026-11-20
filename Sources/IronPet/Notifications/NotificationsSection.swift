import AppKit
import Combine
import SwiftUI

/// What clicking a link in a notification does. Each kind has its own closure so the window, the tests and the previews can supply
/// their own.
struct NotificationLinkOpener {
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Reveals rather than opens: a script or agent wrote the path, and opening could launch an app or a script.
    var openFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var openThread: (String) -> Void = { _ in }
    var openSession: (String) -> Void = { _ in }
    var openTask: (String) -> Void = { _ in }
    var openAlert: (String) -> Void = { _ in }

    func open(_ link: NotificationLink) {
        switch link.kind {
        case .url:
            // Stored rows passed validation, but a row from an older build or by hand might not have.
            guard let url = URL(string: link.ref), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            openURL(url)
        case .file: openFile(URL(fileURLWithPath: (link.ref as NSString).expandingTildeInPath))
        case .thread: openThread(link.ref)
        case .session: openSession(link.ref)
        case .task: openTask(link.ref)
        case .alert: openAlert(link.ref)
        }
    }
}

/// The state of the Notifications section: the list, the filters and which entry is open.
@MainActor
final class NotificationsModel: ObservableObject {
    let api: NotificationsAPI
    @Published var items: [NotificationItem] = []
    @Published var expanded: String?
    @Published var type: NotificationType?
    @Published var source: String?
    @Published private(set) var sources: [String] = []
    /// The unread count, read from the API so the sidebar badge redraws.
    @Published private(set) var unread = 0
    var opener = NotificationLinkOpener()
    private var subscription: APIEventBus.Subscription?

    /// Stands in where the page is not shown.
    static let empty = NotificationsModel(api: .empty())

    /// With `events`, the list and the count read again whenever a notification is added, read or pruned.
    init(api: NotificationsAPI, events: APIEventBus? = nil) {
        self.api = api
        subscription = events?.subscribe { [weak self] event in
            guard event.kind == .notificationsChanged else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() {
        items = api.list(.init(source: source, type: type)).notifications
        sources = api.sources()
        unread = api.unreadCount
    }

    /// Opens or closes a row. Opening it marks it read.
    func toggle(_ id: String) {
        if expanded == id {
            expanded = nil
            return
        }
        select(id)
    }

    /// Opens a row and marks it read. A bubble's click and a row's click both end here.
    func select(_ id: String) {
        expanded = id
        try? api.markRead(id)
        reload()
    }

    /// Back from the detail page.
    func close() { expanded = nil }

    /// The notifications whose title or summary contains `query`, on top of the type and source filters.
    static func filter(_ items: [NotificationItem], query: String) -> [NotificationItem] {
        ListSearch.filter(items, query: query, title: \.title, description: \.summary)
    }

    func markAllRead() {
        api.markAllRead()
        reload()
    }

    /// The source filter's text: the automation id, or `System`.
    static func sourceTitle(_ source: String) -> String {
        source == NotificationItem.systemSource ? "System" : source
    }
}

/// The Notifications section: everything ironpet showed in a bubble, newest first. Clicking one shows its full text and links.
struct NotificationsSection: View {
    @ObservedObject var model: NotificationsModel
    /// A notification a bubble asked to open. Opened, then cleared.
    @Binding var focus: String?
    @State private var search = ""

    var body: some View {
        ListScreen(title: IronPetSection.notifications.title, search: $search, detailOpen: openItem != nil, trailing: {
            HStack(spacing: 10) {
                typeMenu
                sourceMenu
                Button { model.markAllRead() } label: {
                    Label("Mark all as read", systemImage: "envelope.open")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Mark all as read")
                .accessibilityLabel("Mark all as read")
                .disabled(model.unread == 0)
            }
        }) {
            if let item = openItem {
                detail(item)
            } else {
                content
            }
        }
        .onAppear { model.reload(); openFocus() }
        .onChange(of: focus) { _ in openFocus() }
    }

    /// The open notification, if it is still in the list. One pruned while open leaves the list, with its header back.
    private var openItem: NotificationItem? { model.items.first { $0.id == model.expanded } }

    private func openFocus() {
        guard let id = focus else { return }
        focus = nil
        model.type = nil
        model.source = nil
        model.select(id)
    }

    @ViewBuilder private var content: some View {
        let shown = NotificationsModel.filter(model.items, query: search)
        if model.items.isEmpty {
            EmptyState(symbol: "tray", title: model.type == nil && model.source == nil ? "No notifications" : "Nothing matches",
                       detail: "Every bubble Ghost shows is kept here with its full text and links.")
        } else if shown.isEmpty {
            NoMatches()
        } else {
            ListScroll {
                ForEach(shown) { item in
                    NotificationRow(item: item, onOpen: { model.select(item.id) })
                }
            }
        }
    }

    private func detail(_ item: NotificationItem) -> some View {
        ListDetailPage(section: "Notifications", onBack: { model.close() }) {
            HStack(spacing: 8) {
                Image(systemName: item.type.symbol).foregroundStyle(.secondary)
                Text(NotificationsModel.sourceTitle(item.source) + " · " + item.type.title + " · "
                     + item.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.title).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
            if !item.summary.isEmpty, item.summary != item.title {
                Text(item.summary).font(.system(size: 13)).textSelection(.enabled)
            }
            if !item.description.isEmpty, item.description != item.summary {
                Text(NotificationText.markdown(item.description))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !item.links.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.links.enumerated()), id: \.offset) { _, link in
                        Button { model.opener.open(link) } label: {
                            Label(link.title, systemImage: NotificationText.symbol(link.kind))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .help(link.ref)
                    }
                }
            }
        }
        .onExitCommand { model.close() }
    }

    private var typeMenu: some View {
        Menu {
            Button("All types") { model.type = nil; model.reload() }
            Divider()
            ForEach(NotificationType.allCases, id: \.self) { type in
                Button(type.title) { model.type = type; model.reload() }
            }
        } label: {
            Label(model.type?.title ?? "Type", systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .accessibilityLabel("Filter by type")
    }

    private var sourceMenu: some View {
        Menu {
            Button("All sources") { model.source = nil; model.reload() }
            Divider()
            ForEach(model.sources, id: \.self) { source in
                Button(NotificationsModel.sourceTitle(source)) { model.source = source; model.reload() }
            }
        } label: {
            Label(model.source.map(NotificationsModel.sourceTitle) ?? "Source", systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .accessibilityLabel("Filter by source")
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    let onOpen: () -> Void

    var body: some View {
        ListRow(title: item.title, description: item.summary, emphasized: item.isUnread, onOpen: onOpen,
                leading: {
                    HStack(spacing: 6) {
                        Circle().fill(item.isUnread ? Color.accentColor : Color.clear).frame(width: 7, height: 7).padding(.top, 1)
                        ListRowIcon(symbol: item.type.symbol)
                    }
                },
                extra: {
                    Text(NotificationsModel.sourceTitle(item.source) + " · " + item.type.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                },
                trailing: { _ in
                    Text(item.created, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                })
        .accessibilityLabel(item.isUnread ? "Unread: \(item.title)" : item.title)
    }
}

enum NotificationText {
    /// Markdown with the line breaks kept. Text that does not parse shows as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func symbol(_ kind: NotificationLink.Kind) -> String {
        switch kind {
        case .url: return "link"
        case .file: return "doc"
        case .thread: return "bubble.left"
        case .session: return "person.2"
        case .task: return "checklist"
        case .alert: return "bell"
        }
    }
}
