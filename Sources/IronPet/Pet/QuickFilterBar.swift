import struct IronPetKit.QuickFilter
import enum IronPetKit.QuickFilterPrompt
import SwiftUI

/// What the Add or Edit sheet asks the chat agent for.
enum QuickFilterRequest: Identifiable {
    case add
    case edit(QuickFilter)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let filter): return "edit:\(filter.id)"
        }
    }

    var title: String {
        switch self {
        case .add: return "Add a quick filter"
        case .edit(let filter): return "Edit \"\(filter.name)\""
        }
    }

    /// The text sent to the main chat. The agent writes the query; the app only asks.
    func prompt(_ text: String) -> String {
        switch self {
        case .add: return QuickFilterPrompt.add(text)
        case .edit(let filter): return QuickFilterPrompt.edit(filter, text)
        }
    }
}

/// The chips above the task list: "All" first, then the saved quick filters. A chip's right-click menu edits, moves or removes it,
/// and the menu at the end adds one. Adding and editing go to the chat agent, which writes the query.
struct QuickFilterBar: View {
    let filters: [QuickFilter]
    @Binding var selection: String?
    let onAdd: () -> Void
    let onEdit: (QuickFilter) -> Void
    let onRemove: (QuickFilter) -> Void
    /// A step of -1 moves the chip earlier, 1 later.
    let onMove: (QuickFilter, Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chip("All", id: nil)
                    ForEach(filters) { filter in
                        chip(filter.name, id: filter.id)
                            .contextMenu { actions(for: filter) }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            manageMenu
        }
        .padding(.horizontal, ListScreenMetrics.gutter)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick filters")
        .accessibilityIdentifier("quick-filters")
    }

    private func chip(_ title: String, id: String?) -> some View {
        let selected = selection == id
        return Button { selection = id } label: {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07)))
                .overlay(Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("quick-filter-\(id ?? "all")")
        .help(id == nil ? "Show every task" : "Show only tasks that match \"\(title)\"")
    }

    @ViewBuilder private func actions(for filter: QuickFilter) -> some View {
        let index = filters.firstIndex(of: filter)
        Button("Edit…") { onEdit(filter) }
        Button("Move earlier") { onMove(filter, -1) }.disabled(index == 0)
        Button("Move later") { onMove(filter, 1) }.disabled(index == filters.count - 1)
        Divider()
        Button("Remove…", role: .destructive) { onRemove(filter) }
    }

    private var manageMenu: some View {
        Menu {
            Button("Add quick filter…", action: onAdd)
            if !filters.isEmpty {
                Divider()
                ForEach(filters) { filter in
                    Menu(filter.name) { actions(for: filter) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .padding(5)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Manage quick filters")
        .accessibilityIdentifier("quick-filters-manage")
        .help("Add, edit, move or remove quick filters")
    }
}

/// One text field and Send. The text goes to the main chat, where the agent creates or changes the filter.
struct QuickFilterRequestSheet: View {
    let request: QuickFilterRequest
    let petName: String
    let onSend: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.headline)
            TextField("Describe the filter", text: $text, prompt: Text("For example: epic tasks that are not done"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(send)
                .accessibilityIdentifier("quick-filter-description")
            Text("\(petName) writes the filter in the chat.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("quick-filter-send")
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }
}
