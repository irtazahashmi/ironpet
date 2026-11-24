import IronPetKit
import SwiftUI

/// What the Add or Edit sheet asks the chat agent for. The agent writes the query; the phone only asks.
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

    func prompt(_ text: String) -> String {
        switch self {
        case .add: return QuickFilterPrompt.add(text)
        case .edit(let filter): return QuickFilterPrompt.edit(filter, text)
        }
    }
}

/// "All" and the Mac's saved quick filters as chips above the task list. A long press on a chip offers Edit and Remove.
struct QuickFilterChips: View {
    let filters: [QuickFilter]
    @Binding var selection: String?
    let onAdd: () -> Void
    let onEdit: (QuickFilter) -> Void
    let onRemove: (QuickFilter) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", id: nil)
                ForEach(filters) { filter in
                    chip(filter.name, id: filter.id)
                        .contextMenu {
                            Button("Edit…", systemImage: "pencil") { onEdit(filter) }
                            Button("Remove…", systemImage: "trash", role: .destructive) { onRemove(filter) }
                        }
                }
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.footnote.weight(.semibold))
                        .padding(8)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a quick filter")
                .accessibilityIdentifier("quick-filter-add")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .accessibilityIdentifier("quick-filters")
    }

    private func chip(_ title: String, id: String?) -> some View {
        let selected = selection == id
        return Button { selection = id } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
                .overlay(Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("quick-filter-\(id ?? "all")")
    }
}

/// One text field and Send. The text goes to the main chat, where the agent creates or changes the filter.
struct QuickFilterRequestSheet: View {
    let request: QuickFilterRequest
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Describe the filter", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                        .accessibilityIdentifier("quick-filter-description")
                } footer: {
                    Text("Ghost writes the filter in the chat. For example: epic tasks that are not done.")
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(trimmed)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("quick-filter-send")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
