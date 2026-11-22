import IronPetKit
import SwiftUI

struct TasksView: View {
    let model: TasksModel
    @State private var showDone = false
    @AppStorage(TasksViewMode.key) private var modeRaw = TasksViewMode.list.rawValue
    /// A card dropped on Waiting on others, until the person says who holds it.
    @State private var holdingTask: String?
    @State private var holder = ""

    private var mode: TasksViewMode { TasksViewMode(rawValue: modeRaw) ?? .list }

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $modeRaw) {
                        ForEach(TasksViewMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .accessibilityIdentifier("tasks-view-mode")
                }
            }
            .navigationDestination(for: RemoteTask.self) { TaskDetailView(model: model, task: $0) }
            .alert("Waiting on whom?", isPresented: Binding(get: { holdingTask != nil }, set: { if !$0 { holdingTask = nil } })) {
                TextField("Name", text: $holder).accessibilityIdentifier("waiting-name-field")
                Button("Cancel", role: .cancel) {}
                Button("Set") {
                    if let id = holdingTask { let name = holder; Task { _ = await model.hold(id, name: name) } }
                }
            } message: {
                Text("The task moves to Waiting on others.")
            }
        }
        .task { model.start() }
    }

    @ViewBuilder private var content: some View {
        if mode == .board { board } else { list }
    }

    private var board: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).accessibilityIdentifier("tasks-error")
            }
            if !model.suggestions.isEmpty {
                List {
                    Section { ForEach(model.suggestions) { SuggestionRow(suggestion: $0, model: model) } } header: { header("Suggestions", id: "suggestions") }
                }
                .frame(maxHeight: 230)
            }
            TasksBoardView(columns: model.boardColumns, onDrop: drop(_:on:))
        }
    }

    private func drop(_ id: String, on column: BoardColumn) {
        Task {
            if await model.drop(id, on: column) == .needsName {
                holder = ""
                holdingTask = id
            }
        }
    }

    private var list: some View {
            List {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("tasks-error")
                }
                if !model.suggestions.isEmpty {
                    Section { ForEach(model.suggestions) { SuggestionRow(suggestion: $0, model: model) } } header: { header("Suggestions", id: "suggestions") }
                }
                taskSection("Needs you", id: "needs-you", model.needsYou)
                taskSection("In progress", id: "in-progress", model.inProgress)
                taskSection("Backlog", id: "backlog", model.backlog)
                taskSection("Waiting on others", id: "waiting", model.waiting)
                if !model.done.isEmpty {
                    Section {
                        Button { withAnimation { showDone.toggle() } } label: {
                            HStack {
                                Image(systemName: "chevron.right").rotationEffect(.degrees(showDone ? 90 : 0)).foregroundStyle(.secondary)
                                Text("Done (\(model.done.count))").font(.headline)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("section-done")
                        .accessibilityValue(showDone ? "Expanded" : "Collapsed")
                        if showDone { ForEach(model.done) { row($0) } }
                    }
                }
                if model.loaded, model.tasks.isEmpty, model.suggestions.isEmpty {
                    ContentUnavailableView("No tasks", systemImage: "checklist", description: Text("Tasks you add on the Mac show up here."))
                }
            }
            .refreshable { await model.reload() }
    }

    private func header(_ title: String, id: String) -> some View {
        Text(title).textCase(nil).font(.headline).foregroundStyle(.primary).accessibilityIdentifier("section-\(id)")
    }

    @ViewBuilder private func taskSection(_ title: String, id: String, _ items: [RemoteTask]) -> some View {
        if !items.isEmpty {
            Section { ForEach(items) { row($0) } } header: { header(title, id: id) }
        }
    }

    private func row(_ task: RemoteTask) -> some View {
        NavigationLink(value: task) { TaskRow(task: task) }.accessibilityIdentifier("task-\(task.id)")
    }
}

struct TaskRow: View {
    let task: RemoteTask

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).strikethrough(task.status == .done)
            if let line = detail { Text(line).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let waiting = task.waitingOn { parts.append("Waiting on \(waiting)") }
        if let due = task.due { parts.append("Due \(due.formatted(date: .abbreviated, time: .omitted))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct SuggestionRow: View {
    let suggestion: RemoteSuggestion
    let model: TasksModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.title)
            Text(origin).font(.caption).foregroundStyle(.secondary)
            if !suggestion.notes.isEmpty { Text(suggestion.notes).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            HStack {
                Button("Add") { Task { await model.add(suggestion) } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("add-\(suggestion.id)")
                Button("Skip") { Task { await model.skip(suggestion) } }
                    .buttonStyle(.bordered).accessibilityIdentifier("skip-\(suggestion.id)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("suggestion-\(suggestion.id)")
    }

    private var origin: String {
        var text = suggestion.origin == "meeting" ? "Meeting" : (suggestion.originDetail.map { "From \($0)" } ?? "Automation")
        if let waiting = suggestion.waitingOn { text += " · Waiting on \(waiting)" }
        if let due = suggestion.due { text += " · Due \(due)" }
        return text
    }
}

/// The columns side by side, each a bit over half the screen wide, so a column and part of the next are in view and a card can be
/// dropped on the visible part of its neighbour. Scroll sideways for the others. A long press lifts a card.
struct TasksBoardView: View {
    let columns: [BoardColumn: [RemoteTask]]
    let onDrop: (String, BoardColumn) -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(BoardColumn.allCases) { column in
                        BoardColumnView(column: column, tasks: columns[column] ?? [], onDrop: onDrop)
                            .frame(width: max(proxy.size.width * 0.62, 220), height: proxy.size.height - 8)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
        .accessibilityIdentifier("tasks-board")
    }
}

private struct BoardColumnView: View {
    @Environment(\.macAccent) private var macAccent
    let column: BoardColumn
    let tasks: [RemoteTask]
    let onDrop: (String, BoardColumn) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(column.title).font(.headline).accessibilityIdentifier("board-header-\(column.rawValue)")
                Text("\(tasks.count)").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        NavigationLink(value: task) { BoardCard(task: task) }
                            .buttonStyle(.plain)
                            .draggable(task.id)
                            .accessibilityIdentifier("task-\(task.id)")
                            .accessibilityActions {
                                ForEach(BoardColumn.allCases.filter { $0 != BoardColumn.of(task) }) { target in
                                    Button("Move to \(target.title)") { onDrop(task.id, target) }
                                }
                            }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(macAccent, lineWidth: targeted ? 2 : 0))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { onDrop(id, column) }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-column-\(column.rawValue)")
    }
}

private struct BoardCard: View {
    let task: RemoteTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title).font(.subheadline.weight(.medium)).strikethrough(task.status == .done).lineLimit(3)
            if let line = Self.firstLine(task.notes) { Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let waiting = task.waitingOn { Label("Waiting on \(waiting)", systemImage: "person.badge.clock").font(.caption).foregroundStyle(.secondary) }
            if let due = task.due {
                Label("Due \(due.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)))
        .contentShape(Rectangle())
    }

    /// The first non-empty line of the notes, without markdown list or heading marks, as the Mac's cards show it.
    static func firstLine(_ notes: String) -> String? {
        notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-*> ").union(.whitespaces)) }
            .first { !$0.isEmpty }
    }
}
