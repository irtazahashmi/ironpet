import AppKit
import IronPetCore
import IronPetKit
import SwiftUI

/// What the Memory section shows and does: the page list with its chip and search, the stack of open pages and the detail of the
/// page on top. The rules (matching, grouping, forgetting) live in `MemoryBrowser` and `EntityMemoryStore`; this keeps the state.
@MainActor
final class MemorySectionModel: ObservableObject {
    private let provider: @MainActor () -> MemoryAPI?

    @Published var filter: MemoryFilter = .all
    /// What the search field holds.
    @Published var query = ""
    /// The search the list uses: `query` after the debounce.
    @Published private(set) var applied = ""
    @Published private(set) var nav = MemoryNavigation()
    @Published private(set) var rows: [MemoryRow] = []
    /// The title of every page, by id, for the trail.
    @Published private(set) var titles: [String: String] = [:]
    @Published private(set) var detail: MemoryDetail?
    /// The row the keyboard focus ring is on.
    @Published var focused: String?
    /// Bumped to focus the search field.
    @Published private(set) var searchFocus = 0
    /// Chats, meetings and notes that match the search, once the user asked for them.
    @Published private(set) var textHits: [MemoryIndex.Hit]?

    static let debounce: Duration = .milliseconds(250)
    /// The window's model. Tests and `--render-previews` set up its state; the section reads the live memory.
    static let shared = MemorySectionModel()

    init(api: @escaping @MainActor () -> MemoryAPI? = { MemoryAPI.live }) {
        provider = api
    }

    var available: Bool { provider() != nil }
    var list: MemoryList { MemoryBrowser.list(rows, filter: filter, query: applied) }
    var hasPages: Bool { !rows.isEmpty }

    /// The trail over the page: Memory, then every open page.
    var trail: [(id: String, title: String)] { nav.stack.map { ($0, titles[$0] ?? "Page") } }

    func reload() {
        guard let api = provider() else { rows = []; titles = [:]; detail = nil; return }
        rows = api.browseRows()
        titles = Dictionary(api.entities().map { ($0.id, $0.type == .me ? "About me" : $0.name) }, uniquingKeysWith: { a, _ in a })
        nav.prune { titles[$0] != nil }
        detail = nav.current.flatMap { api.detail($0) }
        if let focused, !list.rows.contains(where: { $0.id == focused }) { self.focused = nil }
    }

    // MARK: List

    /// Clicking the selected chip again returns to All.
    func select(_ chip: MemoryFilter) {
        filter = (chip == filter) ? .all : chip
        focused = nil
        textHits = nil
    }

    /// Applies the search text. The view calls it after `debounce`.
    func applyQuery() {
        applied = query
        textHits = nil
        focused = nil
    }

    func clearSearch() {
        query = ""
        applied = ""
        textHits = nil
    }

    func requestSearchFocus() {
        nav.reset()
        detail = nil
        searchFocus += 1
    }

    /// Up (-1) and Down (+1) move the focus ring through the rows shown.
    func moveFocus(_ delta: Int) {
        let ids = list.rows.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = focused, let index = ids.firstIndex(of: current) else { focused = delta > 0 ? ids.first : ids.last; return }
        focused = ids[min(max(index + delta, 0), ids.count - 1)]
    }

    func openFocused() { if let focused { open(focused) } }

    /// The same search `memory_search` runs, over chats, meetings and notes.
    func searchChatsAndMeetings() {
        textHits = provider()?.search(applied, limit: 20) ?? []
    }

    // MARK: Navigation

    func open(_ id: String) {
        nav.push(id)
        detail = provider()?.detail(id)
    }

    func back() {
        nav.back()
        detail = nav.current.flatMap { provider()?.detail($0) }
    }

    func pop(to index: Int) {
        nav.pop(to: index)
        detail = nav.current.flatMap { provider()?.detail($0) }
    }

    func showList() {
        nav.reset()
        detail = nil
    }

    /// Esc: back one page on a detail page; on the list it clears the search, and does nothing when there is none.
    func escape() {
        if nav.isOpen { back() } else if !query.isEmpty || !applied.isEmpty { clearSearch() }
    }

    // MARK: Changes

    func pin(_ claim: MemoryClaim) {
        _ = provider()?.setPinned(claim.id, !claim.pinned)
        reload()
    }

    func forget(_ claim: MemoryClaim) {
        provider()?.forgetClaim(claim.id)
        reload()
    }

    func forgetPage(_ id: String) {
        provider()?.forgetPage(id)
        // The page stays in the store, empty, so the trail drops it by hand.
        nav.prune { $0 != id }
        reload()
    }

    /// Merges the pages into the one on top of the trail, then shows the merged page. Returns the reason when it fails; the pages stay as
    /// they were.
    @discardableResult
    func merge(_ others: [String], into keep: String) -> String? {
        guard let api = provider() else { return "Memory is not available." }
        switch api.mergePages(others, into: keep) {
        case .failure(let failure):
            return failure.message
        case .success:
            // The merged pages are gone, so the trail drops them.
            nav.prune { !others.contains($0) }
            reload()
            return nil
        }
    }

    /// Where a page's Markdown goes. Nil when the page is gone.
    func markdown(of id: String) -> (name: String, text: String)? {
        provider()?.detail(id).map { ($0.title, $0.markdown) }
    }
}

// MARK: - Section

struct MemorySection: View {
    @ObservedObject var model: MemorySectionModel
    let onOpenSource: (MemorySource) -> Void
    let onOpenSettings: () -> Void

    @State private var pendingForget: MemoryRow?
    @FocusState private var searchFocused: Bool

    var body: some View {
        ListScreen(title: IronPetSection.memory.title, search: $model.query, detailOpen: model.nav.isOpen,
                   titleView: model.nav.isOpen ? AnyView(trail) : nil, searchPrompt: "Search pages and facts", searchFocus: $searchFocused,
                   trailing: { if model.hasPages || model.filter != .all { controls } }) {
            ZStack {
                listBody
                    .opacity(model.nav.isOpen ? 0 : 1)
                    .allowsHitTesting(!model.nav.isOpen)
                    .accessibilityHidden(model.nav.isOpen)
                if model.nav.isOpen { detailBody }
            }
        }
        .background { shortcuts }
        .onAppear { model.reload() }
        .task(id: model.query) {
            if model.query == model.applied { return }
            if model.query.isEmpty { model.applyQuery(); return }
            try? await Task.sleep(for: MemorySectionModel.debounce)
            if !Task.isCancelled { model.applyQuery() }
        }
        .onChange(of: model.searchFocus) { _, _ in searchFocused = true }
        .confirmationDialog("Forget \(pendingForget?.name ?? "this page")?", isPresented: Binding(get: { pendingForget != nil },
                                                                                                set: { if !$0 { pendingForget = nil } })) {
            Button("Forget page", role: .destructive) { if let row = pendingForget { model.forgetPage(row.id) }; pendingForget = nil }
        } message: {
            Text("Forgets every fact on the page and its links. This cannot be undone.")
        }
    }

    // MARK: Shortcuts

    /// Hidden buttons that carry the keyboard shortcuts: ⌘F, ⌘[ and Esc.
    private var shortcuts: some View {
        ZStack {
            Button("Search") { model.requestSearchFocus() }.keyboardShortcut("f", modifiers: .command)
            Button("Back") { model.back() }.keyboardShortcut("[", modifiers: .command).disabled(!model.nav.isOpen)
            if model.nav.isOpen || !model.query.isEmpty {
                Button("Escape") { model.escape() }.keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Header

    private var trail: some View {
        HStack(spacing: 6) {
            Button { model.back() } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                .buttonStyle(.borderless)
                .help("Back to \(model.nav.stack.count > 1 ? model.trail[model.nav.stack.count - 2].title : "Memory") (Esc)")
                .accessibilityLabel("Back")
            Button("Memory") { model.showList() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            ForEach(Array(model.trail.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                if index == model.trail.count - 1 {
                    Text(part.title).fontWeight(.semibold).lineLimit(1)
                } else {
                    Button(part.title) { model.pop(to: index) }.buttonStyle(.plain).foregroundStyle(Color.accentColor).lineLimit(1)
                }
            }
        }
        .font(.system(size: 15, weight: .medium))
    }

    private var controls: some View {
        HStack(spacing: 6) { chips }
    }

    private var chips: some View {
        ForEach(MemoryFilter.allCases, id: \.self) { chip in
            MemoryChip(title: chip.title, selected: model.filter == chip) { model.select(chip) }
        }
    }

    // MARK: List

    @ViewBuilder private var listBody: some View {
        let list = model.list
        if !model.available || !model.hasPages && !list.searching {
            emptyState
        } else if list.rows.isEmpty {
            noResults(list)
        } else {
            ScrollViewReader { proxy in
                ListScroll {
                    ForEach(list.rows) { row in
                        MemoryRowView(row: row, needle: list.query.trimmingCharacters(in: .whitespacesAndNewlines),
                                      focused: model.focused == row.id,
                                      onOpen: { model.open(row.id) },
                                      onExport: { export(row.id) }, onForget: { pendingForget = row })
                            .id(row.id)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { model.moveFocus(-1); return .handled }
                .onKeyPress(.downArrow) { model.moveFocus(1); return .handled }
                .onKeyPress(.return) { model.focused == nil ? .ignored : { model.openFocused(); return .handled }() }
                .onChange(of: model.focused) { _, id in if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: SharedSymbolsMemory.symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("No pages yet").font(.system(size: 12.5, weight: .medium))
            Text("Ghost writes a page for each person, project and tool it learns about from your chats, meetings and tasks. Pages appear after the first learning pass.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button(action: onOpenSettings) { Label("Memory settings", systemImage: "gearshape") }
                .controlSize(.small)
                .help("Open Settings > Memory, where learning is turned on")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noResults(_ list: MemoryList) -> some View {
        let others = MemoryBrowser.otherMatches(model.rows, query: list.query, excluding: list.filter)
        let allMatches = list.filter == .all ? 0 : MemoryBrowser.list(model.rows, filter: .all, query: list.query).rows.count
        return ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.tertiary)
                if list.searching {
                    Text("No \(list.filter.noun) match \"\(list.query)\"").font(.system(size: 12.5, weight: .medium))
                    if allMatches > 0 {
                        Text("\(allMatches) page\(allMatches == 1 ? "" : "s") of another type match" + (others.isEmpty ? "." : ": " + others.map { "\($0.count) \($0.filter.noun)" }.joined(separator: ", ") + "."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if list.filter != .all { Button("Show in All") { model.select(list.filter) }.controlSize(.small) }
                        Button("Search chats and meetings") { model.searchChatsAndMeetings() }.controlSize(.small)
                    }
                    if let hits = model.textHits { textHits(hits) }
                } else {
                    Text("No \(list.filter.noun) yet").font(.system(size: 12.5, weight: .medium))
                    Text("Pages of this type appear once Ghost learns about one.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private static func symbol(_ kind: MemoryIndex.Kind) -> String {
        switch kind {
        case .chat: return SharedSymbols.chat
        case .meeting: return "person.2.wave.2"
        case .note: return "note.text"
        }
    }

    private func textHits(_ hits: [MemoryIndex.Hit]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if hits.isEmpty { Text("Nothing found in chats, meetings or notes.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 2) {
                    Label(hit.title, systemImage: Self.symbol(hit.kind)).font(.callout)
                    Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: ListScreenMetrics.maxWidth)
        .padding(.top, 8)
    }

    // MARK: Detail

    @ViewBuilder private var detailBody: some View {
        if let detail = model.detail {
            MemoryDetailView(detail: detail, model: model, onOpenSource: onOpenSource, onExport: { export(detail.entity.id) })
                .id(detail.entity.id)
        } else {
            Color.clear
        }
    }

    private func export(_ id: String) {
        guard let page = model.markdown(of: id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = page.name.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? page.text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum SharedSymbolsMemory { static let symbol = SharedSymbols.memory }

// MARK: - Pieces

private struct MemoryChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 3)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The type badge: always the accent colour, so type is told by the label and the icon.
struct MemoryBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
    }
}

extension EntityType {
    var memorySymbol: String {
        switch self {
        case .me: return "person.crop.circle"
        case .person: return "person"
        case .project: return "folder"
        case .org: return "building.2"
        case .tool: return "hammer"
        case .topic: return "number"
        }
    }
}

/// `text` with every match of `needle` (ignoring case and accents) marked.
enum MemoryHighlight {
    static func text(_ text: String, _ needle: String) -> AttributedString {
        var result = AttributedString(text)
        guard !needle.isEmpty else { return result }
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            if let marked = Range(range, in: result) {
                result[marked].backgroundColor = Color.accentColor.opacity(0.28)
                result[marked].inlinePresentationIntent = .stronglyEmphasized
            }
            from = range.upperBound
        }
        return result
    }
}

private struct MemoryRowView: View {
    let row: MemoryRow
    let needle: String
    let focused: Bool
    let onOpen: () -> Void
    let onExport: () -> Void
    let onForget: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ListRowIcon(symbol: row.type.memorySymbol, color: .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(MemoryHighlight.text(row.name, needle)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    MemoryBadge(text: row.type.label)
                }
                Text(MemoryHighlight.text(row.summary, needle)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Menu {
                    Button("Export page", action: onExport)
                    Button("Forget page", role: .destructive, action: onForget)
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 18) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More: Export page, Forget page")
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(row.factCount) fact\(row.factCount == 1 ? "" : "s")")
                Text(row.updated.map { MemoryDay.label($0) } ?? "").foregroundStyle(.tertiary)
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.09 : 0.05)))
        .overlay { if focused { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), \(row.type.label), \(row.factCount) facts")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open page", onOpen)
        .accessibilityAction(named: "Export page", onExport)
        .accessibilityAction(named: "Forget page", onForget)
    }
}

// MARK: - Detail

/// What the merge confirmation says: which pages go, how many facts move, and that it cannot be undone.
enum MemoryDetailMergeMessage {
    static func text(into detail: MemoryDetail) -> String {
        let pages = detail.possibleDuplicates
        let one = pages.count == 1
        let list = pages.map { "\($0.name) (\($0.facts) fact\($0.facts == 1 ? "" : "s"))" }.joined(separator: ", ")
        let total = detail.facts.count + pages.reduce(0) { $0 + $1.facts }
        return "Moves the facts and links of \(list) onto \(detail.title), keeps \(one ? "its name as an alias" : "their names as aliases"), "
            + "and removes \(one ? "that page" : "those pages"). \(detail.title) will have \(total) fact\(total == 1 ? "" : "s"). This cannot be undone."
    }
}

private struct MemoryDetailView: View {
    let detail: MemoryDetail
    @ObservedObject var model: MemorySectionModel
    let onOpenSource: (MemorySource) -> Void
    let onExport: () -> Void

    @State private var showAllFacts = false
    @State private var showEarlier = false
    @State private var bannerDismissed = false
    @State private var confirmForget = false
    @State private var confirmMerge = false
    @State private var mergeFailure: String?
    @State private var copied = false

    static let collapsedFacts = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                if !detail.possibleDuplicates.isEmpty, !bannerDismissed { banner }
                factsSection
                if !detail.earlier.isEmpty { earlierSection }
                if !detail.linkGroups.isEmpty { linksSection }
            }
            .padding(.horizontal, ListScreenMetrics.gutter + 4)
            .padding(.vertical, 14)
            .listColumn()
        }
        .confirmationDialog("Forget \(detail.title)?", isPresented: $confirmForget) {
            Button("Forget page", role: .destructive) { model.forgetPage(detail.entity.id) }
        } message: {
            Text("Forgets every fact on the page and its links. This cannot be undone.")
        }
        .confirmationDialog("Merge into \(detail.title)?", isPresented: $confirmMerge) {
            Button("Merge pages", role: .destructive) { mergeFailure = model.merge(detail.possibleDuplicates.map(\.page), into: detail.entity.id) }
        } message: {
            Text(MemoryDetailMergeMessage.text(into: detail))
        }
        .alert("Could not merge the pages", isPresented: Binding(get: { mergeFailure != nil }, set: { if !$0 { mergeFailure = nil } })) {
            Button("OK") { mergeFailure = nil }
        } message: {
            Text(mergeFailure ?? "")
        }
    }

    private func date(_ text: String) -> String {
        MemoryDay.parse(text).map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? text
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                MemoryBadge(text: detail.entity.type.label)
                Spacer()
                HStack(spacing: 2) {
                    iconButton("doc.on.doc", help: copied ? "Copied" : "Copy the page id", label: "Copy page id") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(detail.entity.ref, forType: .string)
                        copied = true
                    }
                    iconButton("square.and.arrow.up", help: "Export this page as Markdown", label: "Export page", action: onExport)
                    iconButton("trash", help: "Forget this page", label: "Forget page") { confirmForget = true }
                }
            }
            if !detail.entity.aliases.isEmpty {
                (Text("Also known as ").foregroundStyle(.secondary) + Text(detail.entity.aliases.joined(separator: ", "))).font(.system(size: 13))
            }
            if !detail.entity.identifiers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(detail.entity.identifiers, id: \.self) { id in
                        Text(id).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))).textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 4) {
                Text(meta).foregroundStyle(.secondary)
                Text(detail.entity.ref).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            }
            .font(.system(size: 12.5))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardMaterial()
    }

    private var meta: String {
        var parts = ["\(detail.facts.count) fact\(detail.facts.count == 1 ? "" : "s")" + (detail.pinnedCount > 0 ? ", \(detail.pinnedCount) pinned" : "")]
        if let updated = detail.updated { parts.append("updated \(MemoryDay.label(updated).lowercased())") }
        if let first = detail.firstSeen { parts.append("first seen \(first.formatted(.dateTime.day().month(.abbreviated).year()))") }
        return parts.joined(separator: " · ") + " ·"
    }

    private func iconButton(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel(label)
    }

    /// Other pages that may be the same person. The button merges them into this page after a confirmation.
    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(Color.accentColor)
            bannerText
            Spacer(minLength: 8)
            Button { confirmMerge = true } label: { Image(systemName: "arrow.triangle.merge").frame(width: 24, height: 22) }
                .buttonStyle(.borderless).help("Merge \(detail.possibleDuplicates.count == 1 ? "that page" : "those pages") into this page")
                .accessibilityLabel("Merge into this page")
            Button { bannerDismissed = true } label: { Image(systemName: "xmark.circle").frame(width: 24, height: 22) }
                .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.14)))
    }

    private var bannerText: Text {
        let dupes = detail.possibleDuplicates
        var text = Text(dupes.count == 1 ? "Another page may be this person: " : "\(dupes.count == 2 ? "Two" : "\(dupes.count)") other pages may be this person: ")
        for (index, dupe) in dupes.enumerated() {
            var name = AttributedString(dupe.name)
            name.foregroundColor = .accentColor
            name.link = URL(string: "ironpet-memory://page/\(dupe.page)")
            text = text + Text(name) + Text(" (\(dupe.facts) fact\(dupe.facts == 1 ? "" : "s"))")
            if index < dupes.count - 2 { text = text + Text(", ") } else if index == dupes.count - 2 { text = text + Text(" and ") }
        }
        return text + Text(".")
    }

    // MARK: Facts

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(0.5)
            Text("\(count)").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private var factsSection: some View {
        let shown = showAllFacts ? detail.facts : Array(detail.facts.prefix(Self.collapsedFacts))
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Facts", count: detail.facts.count)
            VStack(alignment: .leading, spacing: 0) {
                if detail.facts.isEmpty {
                    Text("Nothing on this page yet.").font(.callout).foregroundStyle(.secondary).padding(14)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, claim in
                    if index > 0 { Divider() }
                    FactRow(claim: claim, dateText: date(claim.date), onOpenSource: onOpenSource,
                            onPin: { model.pin(claim) }, onForget: { model.forget(claim) })
                }
                if detail.facts.count > Self.collapsedFacts {
                    Divider()
                    Button { showAllFacts.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showAllFacts ? "chevron.down" : "chevron.right").font(.system(size: 10))
                            Text(showAllFacts ? "Show fewer facts" : "Show \(detail.facts.count - Self.collapsedFacts) more facts")
                            Spacer()
                        }
                        .foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 38).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardMaterial()
        }
    }

    private var earlierSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Earlier", count: detail.earlier.count)
            VStack(alignment: .leading, spacing: 0) {
                Button { showEarlier.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showEarlier ? "chevron.down" : "chevron.right").font(.system(size: 10))
                        if showEarlier {
                            Text("Replaced facts, newest first")
                        } else {
                            (Text("Replaced facts, newest first: ") + Text(detail.earlier[0].text).strikethrough()
                                + Text(detail.earlier.count > 1 ? " and \(detail.earlier.count - 1) more" : "")).lineLimit(1)
                        }
                        Spacer()
                    }
                    .foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showEarlier ? "Hide earlier facts" : "Show earlier facts")
                if showEarlier {
                    ForEach(detail.earlier) { claim in
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(claim.text).strikethrough().foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(claim.date.isEmpty ? "" : date(claim.date) + (claim.invalidAt != nil ? ", replaced " : ""))
                                    + Text(claim.invalidAt.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "")
                                ForEach(MemorySource.chips(claim.sources), id: \.kind) { SourceChip(source: $0, action: onOpenSource) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardMaterial()
        }
    }

    // MARK: Links

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Links", count: detail.linkCount)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(detail.linkGroups.enumerated()), id: \.element.id) { index, group in
                    Text(group.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, index == 0 ? 12 : 14).padding(.bottom, 4)
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { itemIndex, item in
                        if itemIndex > 0 { Divider().padding(.horizontal, 14) }
                        Button { model.open(item.page) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.type.memorySymbol).frame(width: 18)
                                Text(item.name).font(.system(size: 13.5))
                                MemoryBadge(text: item.type.label)
                                Spacer(minLength: 8)
                                Text("\(item.count) mention\(item.count == 1 ? "" : "s") · last seen \(MemoryDay.label(item.lastSeen).lowercased())")
                                    .font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.name), \(item.type.label), \(group.title)")
                    }
                }
                Spacer().frame(height: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardMaterial()
        }
    }
}

/// One fact: its text, the day and the sources, a pin and a forget button.
private struct FactRow: View {
    let claim: MemoryClaim
    let dateText: String
    let onOpenSource: (MemorySource) -> Void
    let onPin: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(claim.text).font(.system(size: 13.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text((claim.pinned ? "Pinned · " : "") + dateText).font(.caption).foregroundStyle(.secondary)
                    ForEach(MemorySource.chips(claim.sources), id: \.kind) { SourceChip(source: $0, action: onOpenSource) }
                }
            }
            Button(action: onPin) { Image(systemName: claim.pinned ? "pin.fill" : "pin").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .foregroundStyle(claim.pinned ? Color.accentColor : .secondary)
                .help(claim.pinned ? "Unpin: a newer fact may replace it" : "Pin: a newer fact is added beside it instead of replacing it")
                .accessibilityLabel(claim.pinned ? "Unpin fact" : "Pin fact")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(claim.pinned ? Color.accentColor.opacity(0.10) : Color.clear)
        .contextMenu {
            Button(claim.pinned ? "Unpin" : "Pin", action: onPin)
            Button("Forget fact", role: .destructive, action: onForget)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Forget fact", onForget)
    }
}

private struct SourceChip: View {
    let source: MemorySource
    let action: (MemorySource) -> Void

    var body: some View {
        Button { action(source) } label: {
            Label(source.label, systemImage: source.symbol)
                .font(.system(size: 11.5)).foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(source.kind == .user || source.kind == .other)
        .help(source.kind == .user || source.kind == .other ? source.label : "Open \(source.label.lowercased())")
    }
}
