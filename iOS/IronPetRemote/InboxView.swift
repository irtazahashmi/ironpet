import IronPetKit
import SwiftUI

/// The Inbox tab: the Mac's open items in one group for each place they came from, newest first. A row has the Done circle, the title,
/// when it arrived and, for an item with a link, an Open button. Swiping a row offers Remove. Tapping it opens the item page.
struct InboxView: View {
    let model: InboxModel
    var onShowChat: () -> Void = {}

    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    ForEach(RemoteSuggestion.groups(model.items), id: \.kind) { group in
                        Section {
                            ForEach(group.items) { item in
                                InboxRow(item: item, model: model) { path.append(item.id) }
                            }
                        } header: {
                            InboxGroupTitle(symbol: group.symbol, title: group.title, count: group.items.count)
                        }
                    }
                    if model.loaded, model.items.isEmpty, !model.lastRefreshFailed {
                        ContentUnavailableView("Inbox is empty", systemImage: SharedSymbols.tasks, description: Text("Items from meetings and automations show up here."))
                    }
                }
                .listRowBackground(SharedTheme.card)
            }
            .refreshable { await model.reload() }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in InboxItemPage(id: id, model: model, onShowChat: onShowChat) }
            .themedScreen()
            .fullPageLoadError(model)
            .alert("Could not update the Inbox", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .task { model.start() }
    }
}

private struct InboxGroupTitle: View {
    let symbol: String
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title.uppercased())
            Text("\(count)").foregroundStyle(.tertiary)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// An Open button for an item with a link. The same pill on the row and on the item page.
private struct OpenPill: View {
    let url: URL
    var identifier: String

    var body: some View {
        Link(destination: url) {
            Text("Open")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Open \(url.host ?? "link")")
        .accessibilityIdentifier(identifier)
    }
}

struct InboxRow: View {
    let item: RemoteSuggestion
    let model: InboxModel
    let onShow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await model.done(item) } } label: {
                Image(systemName: "circle").font(.title2).foregroundStyle(.secondary).frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Done")
            .accessibilityIdentifier("done-\(item.id)")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let url = item.openURL { OpenPill(url: url, identifier: "source-\(item.id)") }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onShow)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", role: .destructive) { Task { await model.remove(item) } }
                .accessibilityIdentifier("remove-\(item.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show details", onShow)
        .accessibilityIdentifier("inbox-\(item.id)")
    }

    private var subtitle: String {
        let age = item.created.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        return [age, item.otherSourcesLabel].compactMap { $0 }.joined(separator: " · ")
    }
}

/// An item in full: the title, where it came from, Done, Remove and Open, then the notes and the sources.
struct InboxItemPage: View {
    let id: String
    let model: InboxModel
    var onShowChat: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = model.items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(item)
                    if !item.shownNotes.isEmpty {
                        section("Notes") { Text(item.shownNotes).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                    }
                    sources(item)
                }
                .padding(16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
        } else {
            // The item was done or removed on the Mac or on this phone while the page was open.
            Color.clear.onAppear { dismiss() }
        }
    }

    private func header(_ item: RemoteSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.title2.weight(.bold)).textSelection(.enabled)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.originLine.symbol).font(.footnote).accessibilityHidden(true)
                Text(InboxChatLink.text(item.originLine, time: item.created.formatted(.dateTime.day().month(.abbreviated).hour().minute())))
                    .font(.subheadline)
                    .environment(\.openURL, OpenURLAction { url in show(url) })
            }
            .foregroundStyle(.secondary)
            if let due = item.due, !due.isEmpty {
                Label("Due \(due)", systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Done") { Task { await model.done(item) } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("page-done")
                Button("Remove") { Task { await model.remove(item) } }
                    .buttonStyle(.bordered).accessibilityIdentifier("page-remove")
                Spacer()
                if let url = item.openURL { OpenPill(url: url, identifier: "page-open") }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SharedTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func sources(_ item: RemoteSuggestion) -> some View {
        let rows = item.sourceRows
        if !rows.isEmpty {
            section("Sources") {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 48) }
                        HStack(spacing: 12) {
                            Image(systemName: row.symbol).frame(width: 24).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(row.title)
                            Spacer(minLength: 8)
                            if let title = row.actionTitle { rowLink(row, title) }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                    }
                }
            }
        }
    }

    @ViewBuilder private func rowLink(_ row: InboxSourceRow, _ title: String) -> some View {
        switch row.action {
        case .openURL(let url): Link(title, destination: url).lineLimit(1).truncationMode(.tail)
        case .showChat(let thread): Button(title) { Task { if await model.showChat(thread) { onShowChat() } } }
        case .openMeeting, .none: EmptyView()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
            content().background(SharedTheme.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func show(_ url: URL) -> OpenURLAction.Result {
        guard let thread = InboxChatLink.thread(from: url) else { return .discarded }
        Task { if await model.showChat(thread) { onShowChat() } }
        return .handled
    }
}
