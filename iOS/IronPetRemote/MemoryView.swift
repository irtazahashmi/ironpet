import IronPetKit
import SwiftUI

/// Memory: the pages Ghost keeps about people, projects and tools. The More tab owns the navigation stack, so a page opens as
/// `MoreDestination.memoryPage` and a link inside a page pushes the next one.
struct MemoryView: View {
    @Bindable var model: MemoryModel
    @State private var pendingForget: RemoteMemoryRow?

    var body: some View {
        List {
            Group {
                if let message = model.errorMessage {
                    Label(message, systemImage: SharedSymbols.warning).foregroundStyle(.orange).accessibilityIdentifier("memory-error")
                }
                chips
                if let list = model.list {
                    Text(list.countLabel).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("memory-count")
                    ForEach(list.pages) { row in
                        NavigationLink(value: MoreDestination.memoryPage(row.id)) { MemoryRowView(row: row, needle: model.query) }
                            .accessibilityIdentifier("memory-row-\(row.id)")
                            .swipeActions {
                                Button("Forget", role: .destructive) { pendingForget = row }
                            }
                    }
                    if list.pages.isEmpty { empty(list) }
                }
            }
            .listRowBackground(SharedTheme.card)
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .searchable(text: $model.query, prompt: "Search pages and facts")
        .refreshable { await model.refresh() }
        .task(id: model.query) {
            guard model.loaded else { return }
            try? await Task.sleep(for: MemoryModel.debounce)
            if !Task.isCancelled { await model.reload() }
        }
        .task { model.start() }
        .confirmationDialog("Forget \(pendingForget?.name ?? "this page")?", isPresented: Binding(get: { pendingForget != nil },
                                                                                               set: { if !$0 { pendingForget = nil } }),
                            titleVisibility: .visible) {
            Button("Forget page", role: .destructive) {
                if let row = pendingForget { Task { await model.forgetPage(row.id) } }
                pendingForget = nil
            }
        } message: {
            Text("Forgets every fact on the page and its links. Recently learned in Settings on the Mac can undo it.")
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RemoteMemoryFilter.allCases, id: \.self) { chip in
                    Button { Task { await model.select(chip) } } label: {
                        Text(chip.title).font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(model.filter == chip ? Color.white : Color.primary)
                            .background(Capsule().fill(model.filter == chip ? Color.accentColor : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.filter == chip ? .isSelected : [])
                    .accessibilityIdentifier("memory-chip-\(chip.rawValue)")
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }

    @ViewBuilder private func empty(_ list: RemoteMemoryList) -> some View {
        if model.query.isEmpty, model.filter == .all {
            ContentUnavailableView("No pages yet", systemImage: SharedSymbols.memory,
                                   description: Text("Ghost writes a page for each person, project and tool it learns about from your chats, meetings and tasks."))
        } else if model.query.isEmpty {
            ContentUnavailableView("No \(model.filter.rawValue) yet", systemImage: SharedSymbols.memory)
        } else {
            ContentUnavailableView {
                Label("No match", systemImage: "magnifyingglass")
            } description: {
                Text("No \(model.filter == .all ? "pages" : model.filter.rawValue) match \"\(model.query)\"." + (list.otherMatches.isEmpty ? "" : " \(list.otherMatches.values.reduce(0, +)) in another type."))
            } actions: {
                if model.filter != .all { Button("Show in All") { Task { await model.select(model.filter) } } }
            }
            .accessibilityIdentifier("memory-no-results")
        }
    }
}

private struct MemoryRowView: View {
    let row: RemoteMemoryRow
    let needle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: MemoryType.symbol(row.type)).foregroundStyle(Color.accentColor).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.headline).lineLimit(1)
                    MemoryTypeBadge(text: row.typeLabel)
                }
                Text(row.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text("\(row.factCount) fact\(row.factCount == 1 ? "" : "s")" + (row.updated.map { " · " + MemoryDay.label($0) } ?? ""))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MemoryTypeBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.accentColor.opacity(0.14)))
    }
}

enum MemoryType {
    static func symbol(_ type: String) -> String {
        switch type {
        case "me": return "person.crop.circle"
        case "person": return "person"
        case "project": return "folder"
        case "org": return "building.2"
        case "tool": return "hammer"
        default: return "number"
        }
    }
}

/// One page in full: facts (pinned first), the facts it replaced, and links that push the linked page.
struct MemoryPageView: View {
    @Bindable var model: MemoryModel
    let id: String
    @State private var showAllFacts = false
    @State private var confirmForget = false
    @Environment(\.dismiss) private var dismiss

    private static let collapsed = 5

    var body: some View {
        List {
            Group {
                if let message = model.errorMessage {
                    Label(message, systemImage: SharedSymbols.warning).foregroundStyle(.orange)
                }
                if let page = model.pages[id] { content(page) }
            }
            .listRowBackground(SharedTheme.card)
        }
        .navigationTitle(model.pages[id]?.title ?? "Memory")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .refreshable { await model.loadPage(id) }
        .task { await model.loadPage(id) }
        .onChange(of: model.forgottenPages) { _, gone in if gone.contains(id) { dismiss() } }
        .toolbar {
            Menu {
                Button(role: .destructive) { confirmForget = true } label: { Label("Forget page", systemImage: "trash") }
            } label: { Image(systemName: SharedSymbols.more) }
                .accessibilityIdentifier("memory-page-menu")
        }
        .confirmationDialog("Forget \(model.pages[id]?.title ?? "this page")?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget page", role: .destructive) { Task { await model.forgetPage(id) } }
        } message: {
            Text("Forgets every fact on the page and its links. Recently learned in Settings on the Mac can undo it.")
        }
    }

    @ViewBuilder private func content(_ page: RemoteMemoryPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MemoryTypeBadge(text: page.typeLabel)
            if !page.aliases.isEmpty { Text("Also known as \(page.aliases.joined(separator: ", "))").font(.subheadline) }
            ForEach(page.identifiers, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
            Text(meta(page)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("memory-header")
        Section("Facts \(page.facts.count)") {
            ForEach(showAllFacts ? page.facts : Array(page.facts.prefix(Self.collapsed))) { fact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.text)
                    Text(([fact.pinned ? "Pinned" : nil, fact.dateText.isEmpty ? nil : fact.dateText] + MemorySource.chips(fact.sources).map { Optional($0.label) })
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .listRowBackground(fact.pinned ? Color.accentColor.opacity(0.12) : SharedTheme.card)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("memory-fact-\(fact.id)")
                .swipeActions(edge: .leading) {
                    Button(fact.pinned ? "Unpin" : "Pin", systemImage: fact.pinned ? "pin.slash" : "pin") { Task { await model.pin(fact, on: id) } }
                        .tint(.accentColor)
                }
                .swipeActions(edge: .trailing) {
                    Button("Forget", role: .destructive) { Task { await model.forget(fact, on: id) } }
                }
                .contextMenu {
                    Button(fact.pinned ? "Unpin" : "Pin") { Task { await model.pin(fact, on: id) } }
                    Button("Forget fact", role: .destructive) { Task { await model.forget(fact, on: id) } }
                }
            }
            if page.facts.count > Self.collapsed {
                Button(showAllFacts ? "Show fewer facts" : "Show \(page.facts.count - Self.collapsed) more facts") { showAllFacts.toggle() }
                    .accessibilityIdentifier("memory-show-more")
            }
        }
        if !page.earlier.isEmpty {
            Section("Earlier \(page.earlier.count)") {
                DisclosureGroup("Replaced facts, newest first") {
                    ForEach(page.earlier) { fact in
                        Text(fact.text).strikethrough().foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("memory-earlier")
            }
        }
        ForEach(page.linkGroups) { group in
            Section(group.title) {
                ForEach(group.links) { link in
                    NavigationLink(value: MoreDestination.memoryPage(link.id)) {
                        HStack {
                            Image(systemName: MemoryType.symbol(link.type)).frame(width: 22)
                            Text(link.name)
                            MemoryTypeBadge(text: link.typeLabel)
                            Spacer()
                            Text("\(link.mentions)×").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("memory-link-\(link.id)")
                }
            }
        }
    }

    private func meta(_ page: RemoteMemoryPage) -> String {
        var parts = ["\(page.facts.count) fact\(page.facts.count == 1 ? "" : "s")"]
        let pinned = page.facts.filter(\.pinned).count
        if pinned > 0 { parts[0] += ", \(pinned) pinned" }
        if let updated = page.updated { parts.append("updated \(MemoryDay.label(updated).lowercased())") }
        parts.append(page.id)
        return parts.joined(separator: " · ")
    }
}
