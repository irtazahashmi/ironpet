import AppKit
import enum IronPetKit.SharedTheme
import enum IronPetKit.SharedSymbols
import IronPetCore
import SwiftUI

/// A task in full, one card per section: chips and title, a summary of status, due date, waiting on, project and source, then
/// notes, links, labels and history. The toolbar in the top bar holds the same actions as the iPhone's menu.
struct TaskDetailPage: View {
    @ObservedObject var tasks: TasksAPI
    let id: String
    let onBack: () -> Void
    let onOpen: (TaskLink) -> Void

    @State private var title = ""
    @State private var waiting = ""
    @State private var editingWaiting = false
    @State private var editingNotes = false
    @State private var draft = ""
    @State private var confirmingDone = false
    @State private var closingNote = ""
    @State private var events: [TaskEvent] = []
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var waitingFocused: Bool

    var body: some View {
        if let task = tasks.task(id) {
            VStack(spacing: 0) {
                topBar(task)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(task)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardMaterial()
                        if confirmingDone { doneCard }
                        if let error {
                            Text(error).font(.callout).foregroundStyle(.red)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).cardMaterial()
                        }
                        summary(task)
                        notes(task)
                        if !task.links.isEmpty { links(task) }
                        labels(task)
                        history
                    }
                    .padding(.horizontal, ListScreenMetrics.gutter + 4)
                    .padding(.vertical, 14)
                    .listColumn()
                }
            }
            .onAppear { sync(task); events = tasks.history(id) }
            .onChange(of: task.title) { if !titleFocused { title = task.title } }
            .onChange(of: task.waitingOn) { if !waitingFocused { waiting = task.waitingOn ?? "" } }
            .onChange(of: task.updated) { events = tasks.history(id) }
            .onExitCommand(perform: goBack)
        } else {
            // The task was deleted while it was open.
            Color.clear.onAppear(perform: onBack)
        }
    }

    private func sync(_ task: TaskItem) {
        title = task.title
        waiting = task.waitingOn ?? ""
        editingWaiting = false
    }

    /// Esc while editing the notes leaves the editor first, so a draft is not lost by accident.
    private func goBack() {
        if editingNotes { editingNotes = false } else { onBack() }
    }

    // MARK: Top bar

    private func topBar(_ task: TaskItem) -> some View {
        HStack(spacing: 6) {
            Button(action: goBack) { Label("Tasks", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back to Tasks")
                .help("Back to the list (Esc)")
            Spacer()
            Button { startNote(task) } label: { Label("Add note", systemImage: "square.and.pencil") }
                .help("Add to the notes")
            Menu {
                ForEach(TaskStatus.allCases.filter { $0 != task.status }, id: \.self) { status in
                    Button(status.title) { changeStatus(to: status, task) }
                }
            } label: { Label("Status", systemImage: "arrow.triangle.2.circlepath") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Change the status")
            if task.status != .done {
                Button { closingNote = ""; confirmingDone = true } label: { Label("Close with a note", systemImage: "checkmark.circle") }
                    .help("Mark done and say what shows it")
            }
            if let first = task.links.first {
                Button { onOpen(first) } label: { Text("Open \(TaskLinkRow(link: first).pullRequestKey.map { _ in "PR" } ?? "link")") + Text(" \u{2197}") }
                    .buttonStyle(.borderedProminent)
                    .help(first.help)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, ListScreenMetrics.gutter - 2)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func startNote(_ task: TaskItem) {
        let existing = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? "" : existing + "\n\n"
        editingNotes = true
    }

    // MARK: Header

    private func header(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            chips(task)
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
                .focused($titleFocused)
                .onSubmit { commitTitle(task) }
                .onChange(of: titleFocused) { if !titleFocused { commitTitle(task) } }
                .accessibilityLabel("Task title")
            Text("Created \(TaskDetail.time(task.created))")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let ref = task.ref { RecordIDLine(ref: ref) }
        }
    }

    private func chips(_ task: TaskItem) -> some View {
        HStack(spacing: 8) {
            if let project = task.projectLabel { Chip(text: project, tint: .purple) }
            Chip(text: task.waitingLabel ?? task.status.title, tint: .orange)
            if let key = task.links.lazy.compactMap({ TaskLinkRow(link: $0).pullRequestKey }).first { Chip(text: key, tint: .gray) }
        }
    }

    private func statusPicker(_ task: TaskItem) -> some View {
        Picker("Status", selection: Binding(get: { task.status }, set: { changeStatus(to: $0, task) })) {
            ForEach(TaskStatus.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Status")
    }

    private func changeStatus(to status: TaskStatus, _ task: TaskItem) {
        guard status != task.status else { return }
        if status == .done {
            closingNote = ""
            confirmingDone = true
        } else {
            confirmingDone = false
            attempt { _ = try TaskEdits.setStatus(status, of: id, in: tasks) }
        }
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What shows it is done?").font(.system(size: 13, weight: .semibold))
            TextField("Closing note (optional)", text: $closingNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(finishDone)
            HStack {
                Button("Mark done", action: finishDone).keyboardShortcut(.defaultAction)
                Button("Cancel") { confirmingDone = false }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardMaterial()
    }

    private func finishDone() {
        confirmingDone = false
        attempt { _ = try TaskEdits.setStatus(.done, of: id, in: tasks, note: closingNote) }
    }

    private func commitTitle(_ task: TaskItem) {
        guard title != task.title else { return }
        attempt({ _ = try TaskEdits.setTitle(title, of: id, in: tasks) }, onFail: { title = task.title })
    }

    private func commitWaiting(_ task: TaskItem) {
        let trimmed = waiting.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == (task.waitingOn ?? "") {
            if trimmed.isEmpty { editingWaiting = false }
            return
        }
        attempt({ _ = try TaskEdits.setWaitingOn(waiting, of: id, in: tasks) }, onFail: { waiting = task.waitingOn ?? "" })
        if trimmed.isEmpty { editingWaiting = false }
    }

    private func attempt(_ work: () throws -> Void, onFail: () -> Void = {}) {
        do { try work(); error = nil } catch {
            self.error = (error as? TaskError)?.message ?? error.localizedDescription
            onFail()
        }
    }

    // MARK: Summary

    private func summary(_ task: TaskItem) -> some View {
        VStack(spacing: 0) {
            SummaryRow(label: "Status", symbol: "circle.lefthalf.filled") { statusPicker(task) }
            Divider()
            SummaryRow(label: "Due", symbol: "calendar") {
                if task.due != nil {
                    DuePicker(due: task.due, disabled: task.status == .done) { new in attempt { _ = try TaskEdits.setDue(new, of: id, in: tasks) } }
                } else {
                    NoneWithSet(action: "Set date", disabled: task.status == .done) {
                        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
                        attempt { _ = try TaskEdits.setDue(tomorrow, of: id, in: tasks) }
                    }
                }
            }
            Divider()
            SummaryRow(label: "Waiting on", symbol: "person.badge.clock") {
                if task.waitingOn != nil || editingWaiting {
                    TextField("Waiting on", text: $waiting)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($waitingFocused)
                        .onAppear { if editingWaiting { waitingFocused = true } }
                        .onSubmit { commitWaiting(task) }
                        .onChange(of: waitingFocused) { if !waitingFocused { commitWaiting(task) } }
                        .accessibilityLabel("Waiting on")
                } else {
                    NoneWithSet(action: "Set") { editingWaiting = true }
                }
            }
            Divider()
            SummaryRow(label: "Project", symbol: "house") {
                if let project = task.projectLabel {
                    Text(project).textSelection(.enabled)
                } else {
                    NoneWithSetLabel(others: otherLabels, own: task.labels) { key, value in
                        TaskLabelEditing.add(key: key, value: value, to: id, in: tasks)
                    }
                }
            }
            Divider()
            SummaryRow(label: "Source", symbol: "arrow.turn.down.right") {
                Text(sourceText(task)).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
        }
        .cardMaterial()
    }

    private var otherLabels: [[String: String]] { tasks.items.filter { $0.id != id }.map(\.labels) }

    private func sourceText(_ task: TaskItem) -> String {
        let origin = TaskDetail.originFields(task.sourceRef).first?.value
        return [task.source.rawValue, origin].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Notes

    private func notes(_ task: TaskItem) -> some View {
        CardSection(title: "Notes", trailing: {
            if editingNotes {
                Button("Cancel") { editingNotes = false }
                Button("Save") { saveNotes() }.keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
            } else {
                Button(task.notes.isEmpty ? "Add notes" : "Edit") { draft = task.notes; editingNotes = true }
                    .buttonStyle(.link)
            }
        }) {
            if editingNotes {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $draft)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Notes as markdown")
                    Text("Markdown. \(draft.utf8.count) of \(TaskValidator.maxNotes) bytes.")
                        .font(.caption).foregroundStyle(draft.utf8.count > TaskValidator.maxNotes ? .red : .secondary)
                }
                .padding(12)
            } else if task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No notes.").font(.system(size: 14)).foregroundStyle(.secondary).padding(12)
            } else {
                MarkdownView(text: task.notes.trimmingCharacters(in: .whitespacesAndNewlines), size: 14).padding(12)
            }
        }
    }

    private func saveNotes() {
        let before = tasks.task(id)?.notes
        attempt { _ = try TaskEdits.setNotes(draft, of: id, in: tasks) }
        if error == nil || tasks.task(id)?.notes != before { editingNotes = error != nil }
    }

    // MARK: Links

    private func links(_ task: TaskItem) -> some View {
        CardSection(title: "Links") {
            let rows = Array(task.links.map(TaskLinkRow.init).enumerated())
            ForEach(rows, id: \.offset) { index, row in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    Image(systemName: row.symbol).frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.pullRequestKey.map { "PR \($0.split(separator: " ").last ?? "")" } ?? row.title).font(.system(size: 13.5))
                        Text(row.reference).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button { onOpen(row.link) } label: { Text("Open \u{2197}") }
                        .buttonStyle(.link)
                        .help(row.link.help)
                        .accessibilityLabel(row.link.help)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
    }

    // MARK: Labels

    private func labels(_ task: TaskItem) -> some View {
        CardSection(title: "Labels") {
            ChipFlow(spacing: 6) {
                ForEach(task.labels.sorted { $0.key < $1.key }, id: \.key) { key, value in
                    HStack(spacing: 4) {
                        Text("\(key): \(value)").textSelection(.enabled)
                        Button { attempt { _ = try tasks.update(UpdateTaskRequest(id: id, removeLabels: [key])) } } label: { Image(systemName: SharedSymbols.deny).font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove label \(key)")
                            .help("Remove \(key)")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.18)))
                }
                AddLabelButton(others: otherLabels, own: task.labels) { key, value in
                    TaskLabelEditing.add(key: key, value: value, to: id, in: tasks)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: History

    private var history: some View {
        CardSection(title: "History") {
            if events.isEmpty {
                Text("No history yet.").font(.system(size: 13)).foregroundStyle(.secondary).padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                        if index > 0 { Divider() }
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8).padding(.top, 5).accessibilityHidden(true)
                            Text(TaskDetail.time(event.at)).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            (Text(event.kind.rawValue.capitalized) + Text(" \(event.detail), by \(event.by)").foregroundStyle(.secondary))
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Task-specific pieces

private struct NoneWithSet: View {
    var word = "None"
    let action: String
    var disabled = false
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("\(word) \u{00B7}").foregroundStyle(.secondary)
            Button(action, action: perform).buttonStyle(.link).disabled(disabled)
        }
    }
}

private struct NoneWithSetLabel: View {
    let others: [[String: String]]
    let own: [String: String]
    let onAdd: (String, String) -> String?
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            Text("None \u{00B7}").foregroundStyle(.secondary)
            Button("Set") { shown = true }
                .buttonStyle(.link)
                .popover(isPresented: $shown, arrowEdge: .bottom) {
                    LabelPopover(others: others, own: own, initialKey: "project", onAdd: onAdd) { shown = false }
                }
        }
    }
}

// MARK: - Pieces

/// The due date: a button to set one, then a date picker (with an optional time) and a clear button.
private struct DuePicker: View {
    let due: Date?
    let disabled: Bool
    let onChange: (Date?) -> Void

    private var hasTime: Bool { due.map { !TaskDue.isAllDay($0, calendar: .current) } ?? false }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").foregroundStyle(.secondary).accessibilityHidden(true)
            if let due {
                DatePicker("Due", selection: Binding(get: { due }, set: { onChange($0) }),
                           displayedComponents: hasTime ? [.date, .hourAndMinute] : .date)
                    .labelsHidden()
                    .accessibilityLabel("Due date")
                Button(hasTime ? "Date only" : "Add time") {
                    onChange(hasTime ? Calendar.current.startOfDay(for: due)
                                     : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due))
                }
                .buttonStyle(.borderless)
                Button { onChange(nil) } label: { Image(systemName: SharedSymbols.removeAttachment) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear due date")
            } else {
                Button("Set due date") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
                    onChange(tomorrow)
                }
                .disabled(disabled)
            }
        }
    }
}

/// "+ Label" and its popover: a key field, a value field, suggestions for both, and the validation message.
private struct AddLabelButton: View {
    let others: [[String: String]]
    let own: [String: String]
    /// Returns nil when added, or the message to show.
    let onAdd: (String, String) -> String?
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: { Label("Label", systemImage: "plus").font(.system(size: 12)) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Add label")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                LabelPopover(others: others, own: own, onAdd: onAdd) { shown = false }
            }
    }
}

struct LabelPopover: View {
    let others: [[String: String]]
    let own: [String: String]
    var initialKey = ""
    let onAdd: (String, String) -> String?
    let onDone: () -> Void
    @State private var key = ""
    @State private var value = ""
    @State private var error: String?
    @FocusState private var field: Field?
    private enum Field { case key, value }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add label").font(.headline)
            TextField("key", text: $key)
                .focused($field, equals: .key)
                .onSubmit { field = .value }
                .accessibilityLabel("Label key")
            if field == .key || value.isEmpty {
                suggestions(TaskLabelEditing.keySuggestions(for: key, others: others, own: own)) { key = $0; field = .value }
            }
            TextField("value", text: $value)
                .focused($field, equals: .value)
                .onSubmit(add)
                .accessibilityLabel("Label value")
            if field == .value {
                suggestions(TaskLabelEditing.valueSuggestions(for: value, key: key.trimmingCharacters(in: .whitespaces), others: others)) {
                    value = $0
                    add()
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(key.isEmpty || value.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .frame(width: 260)
        .onAppear { if key.isEmpty { key = initialKey }; field = key.isEmpty ? .key : .value }
        .onChange(of: key) { error = nil }
    }

    @ViewBuilder private func suggestions(_ items: [String], pick: @escaping (String) -> Void) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.prefix(5), id: \.self) { item in
                    Button { pick(item) } label: {
                        Text(item).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).padding(.horizontal, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }

    private func add() {
        error = onAdd(key, value)
        if error == nil { onDone() }
    }
}

/// Lays children left to right and wraps to a new line when the width runs out.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
