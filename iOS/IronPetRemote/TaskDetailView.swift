import IronPetKit
import SwiftUI

struct TaskDetailView: View {
    let model: TasksModel
    let task: RemoteTask
    @State private var detail: RemoteTaskDetail?
    @State private var sheet: Sheet?
    @Environment(\.dismiss) private var dismiss

    enum Sheet: Identifiable {
        case close, note, status, edit
        var id: Self { self }
    }

    /// The list's copy changes when the Mac sends `tasks.changed`, so the detail reads the newest one it has.
    private var current: RemoteTask { detail?.task ?? model.tasks.first { $0.id == task.id } ?? task }

    var body: some View {
        List {
            Group {
                Section {
                    Text(current.title).font(.headline)
                    LabeledContent("Status", value: current.waitingOn.map { "Waiting on \($0)" } ?? current.status.title)
                    LabeledContent("Assignee", value: model.assigneeName(current))
                    if let due = current.due { LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .omitted)) }
                    LabeledContent("From", value: current.source)
                    if let ref = current.ref { RecordIDLine(ref: ref) }
                }
                if !current.notes.isEmpty { Section("Notes") { Text(current.notes) } }
                if !current.links.isEmpty {
                    Section("Links") {
                        ForEach(current.links, id: \.self) { link in
                            if link.kind == "url", let url = URL(string: link.ref) { Link(link.label ?? link.ref, destination: url) } else {
                                LabeledContent(link.label ?? link.kind, value: link.ref)
                            }
                        }
                    }
                }
                if let history = detail?.history, !history.isEmpty {
                    Section("History") {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(event.kind.capitalized) by \(event.by)").font(.subheadline)
                                if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary) }
                                Text(event.at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
        
            }.listRowBackground(SharedTheme.card)
        }
        .navigationTitle("Task")
        .themedScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if current.status != .done {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Close with a note", systemImage: "checkmark.circle") { sheet = .close }
                        Button("Add a note", systemImage: "note.text.badge.plus") { sheet = .note }
                        Button("Change status", systemImage: "arrow.triangle.2.circlepath") { sheet = .status }
                        Button("Edit title and notes", systemImage: "pencil") { sheet = .edit }
                    } label: { Label("Actions", systemImage: SharedSymbols.more) }
                        .accessibilityIdentifier("task-actions")
                }
            } else {
                ToolbarItem(placement: .primaryAction) { Button("Add a note") { sheet = .note } }
            }
        }
        .task(id: model.tasks) { detail = await model.detail(task.id) ?? detail }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .close:
                NoteSheet(title: "Close task", prompt: "Say what shows the task is done", action: "Close") { note, _ in
                    await model.close(task.id, note: note)
                }
            case .note:
                NoteSheet(title: "Add a note", prompt: "Note", action: "Add") { note, _ in
                    await model.addNote(task.id, note: note)
                }
            case .edit:
                TaskEditSheet(mode: .edit(title: current.title, notes: current.notes)) { title, notes in
                    await model.edit(task.id, title: title, notes: notes)
                }
            case .status:
                NoteSheet(title: "Change status", prompt: "Say why the status changes", action: "Change", statuses: TaskStatus.allCases.filter { $0 != .someday }, initial: current.status) { note, status in
                    await model.setStatus(task.id, status: status ?? current.status, note: note)
                }
            }
        }
    }
}

/// A note field with a confirm button, and an optional status picker. The sheet closes when `submit` returns true.
struct NoteSheet: View {
    let title: String
    let prompt: String
    let action: String
    var statuses: [TaskStatus] = []
    var initial: TaskStatus = .backlog
    let submit: (String, TaskStatus?) async -> Bool

    @State private var note = ""
    @State private var status: TaskStatus = .backlog
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if !statuses.isEmpty {
                        Picker("Status", selection: $status) { ForEach(statuses, id: \.self) { Text($0.title).tag($0) } }
                    }
                    Section(prompt) {
                        TextField(prompt, text: $note, axis: .vertical).lineLimit(2...8).accessibilityIdentifier("note-field")
                    }
            
                }.listRowBackground(SharedTheme.card)
            }
            .navigationTitle(title)
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action) {
                        working = true
                        Task {
                            let ok = await submit(note.trimmingCharacters(in: .whitespacesAndNewlines), statuses.isEmpty ? nil : status)
                            working = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(working || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("note-confirm")
                }
            }
            .onAppear { status = initial }
        }
        .presentationDetents([.medium])
    }
}


/// A title and notes form, for a new task or for editing one. The sheet closes when `submit` returns true, which it does for a change
/// that is saved on the phone and waiting for the Mac.
struct TaskEditSheet: View {
    enum Mode {
        case create
        case edit(title: String, notes: String)
    }

    let mode: Mode
    let submit: (String, String) async -> Bool

    @State private var title = ""
    @State private var notes = ""
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    private var heading: String { if case .create = mode { return "New task" } else { return "Edit task" } }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("Title") { TextField("Title", text: $title).accessibilityIdentifier("task-title-field") }
                    Section("Notes") { TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...8).accessibilityIdentifier("task-notes-field") }
                }.listRowBackground(SharedTheme.card)
            }
            .navigationTitle(heading)
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        working = true
                        Task {
                            let ok = await submit(title, notes)
                            working = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("task-save")
                }
            }
            .onAppear {
                if case .edit(let current, let currentNotes) = mode { title = current; notes = currentNotes }
            }
        }
        .presentationDetents([.medium])
    }
}
