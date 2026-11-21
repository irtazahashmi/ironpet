import AppKit
import IronPetCore
import SwiftUI

/// The Tasks section of the ironpet window. The agent owns the list; here the user can only mark a task done, delete it,
/// and add or skip suggestions from meetings and watchers. Clicking a row shows everything stored about it.
/// Anything else goes to the chat through "Tell Ghost…".
struct TaskListView: View {
    @ObservedObject var tasks: TasksAPI
    let onTellGhost: (String) -> Void
    let onOpenThread: (String) -> Void
    let onOpenSession: (String) -> Void
    /// A task to scroll to and highlight, set by the Today page. Cleared once shown.
    var focus: Binding<String?> = .constant(nil)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDone = false
    @State private var message = ""
    @State private var highlighted: String?
    /// The label the list is filtered by, as `key=value`. Nil shows every task.
    @State private var labelFilter: String?
    @State private var nav = TaskNavigation()
    /// The suggestion open in full. Suggestions have no page of their own in the store, so they get a simple one.
    @State private var suggestionNav = ListNavigation<String>()
    @State private var search = ""
    @AppStorage(TaskViewMode.key) private var modeRaw = TaskViewMode.list.rawValue
    /// A card dropped on Waiting on others, until the user says who holds it.
    @State private var holdingTask: String?
    @State private var holder = ""

    private var mode: TaskViewMode { TaskViewMode(rawValue: modeRaw) ?? .list }

    enum Content: Equatable { case unavailable, empty, list }

    /// Tasks held in memory stay visible. With none, the unavailable state replaces "No tasks yet", which would be wrong while the real list is out of reach.
    static func content(unavailable: Bool, isEmpty: Bool) -> Content { !isEmpty ? .list : unavailable ? .unavailable : .empty }

    var body: some View {
        ListScreen(title: IronPetSection.tasks.title, search: $search, detailOpen: nav.opened != nil || suggestionNav.opened != nil, trailing: { viewModePicker; labelFilterMenu }) {
            // The list stays in the hierarchy under the detail page so its scroll position survives opening a task.
            ZStack {
                listPage
                    .opacity(isDetailOpen ? 0 : 1)
                    .allowsHitTesting(!isDetailOpen)
                    .accessibilityHidden(isDetailOpen)
                if let id = nav.opened {
                    TaskDetailPage(tasks: tasks, id: id, onBack: { nav.close() }, onOpen: open(_:))
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
                        .transition(.opacity)
                } else if let id = suggestionNav.opened {
                    suggestionPage(id)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
                        .transition(.opacity)
                }
            }
            .alert("Waiting on whom?", isPresented: holdingAlertShown) {
                TextField("Name", text: $holder)
                Button("Cancel", role: .cancel) {}
                Button("Set") { if let id = holdingTask { TaskBoard.hold(id, name: holder, tasks: tasks) } }
            } message: {
                Text("The task moves to Waiting on others.")
            }
        }
    }

    private var holdingAlertShown: Binding<Bool> {
        Binding(get: { holdingTask != nil }, set: { if !$0 { holdingTask = nil } })
    }

    private var isDetailOpen: Bool { nav.opened != nil || suggestionNav.opened != nil }

    @ViewBuilder private func suggestionPage(_ id: String) -> some View {
        if let suggestion = tasks.suggestions.first(where: { $0.id == id }) {
            ListDetailPage(section: "Tasks", onBack: { suggestionNav.close() }) {
                Text(suggestion.title).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Button("Add") { _ = try? tasks.accept(AcceptSuggestionRequest(id: suggestion.id)); suggestionNav.close() }
                    Button("Skip") { tasks.skip(suggestion.id); suggestionNav.close() }
                }
                .buttonStyle(.bordered)
                TaskDetailView(detail: TaskDetail(suggestion: suggestion), onOpen: open(_:))
            }
        } else {
            // The suggestion was added or skipped elsewhere while it was open.
            Color.clear.onAppear { suggestionNav.close() }
        }
    }

    private var listPage: some View {
        VStack(spacing: 0) {
            if let reason = tasks.unavailable {
                DatabaseBanner(reason: reason)
            }
            let content = Self.content(unavailable: tasks.unavailable != nil, isEmpty: tasks.suggestions.isEmpty && tasks.all.isEmpty)
            let columns = Self.columns(tasks.all, label: labelFilter, query: search)
            let nothingShown = suggestionRows.isEmpty && columns.isEmpty
            if content == .unavailable {
                Spacer()
            } else if content == .empty {
                EmptyState(symbol: "checklist", title: "No tasks yet",
                           detail: "Ask \(petName) to keep track of something, or finish a meeting.")
            } else if nothingShown {
                NoMatches()
            } else if mode == .board {
                if !suggestionRows.isEmpty {
                    ListScroll { suggestions }.frame(maxHeight: 190)
                    Divider()
                }
                TaskBoardView(columns: columns, highlighted: highlighted, onOpen: { nav.open($0) },
                              onDrop: drop(_:on:))
                    .onAppear { reveal(focus.wrappedValue, nil) }
                    .onChange(of: focus.wrappedValue) { reveal(focus.wrappedValue, nil) }
            } else {
                ScrollViewReader { proxy in
                    ListScroll {
                        suggestions
                        ForEach([TaskColumn.needsYou, .inProgress, .backlog], id: \.self) { column in
                            let items = columns[column] ?? []
                            if !items.isEmpty {
                                ListGroupTitle(column.title)
                                ForEach(items) { row($0) }
                            }
                        }
                        if let items = columns[.waiting], !items.isEmpty {
                            ListGroupTitle(TaskColumn.waiting.title)
                            ForEach(items) { row($0) }
                        }
                        doneSection(columns[.done] ?? [])
                    }
                    .onAppear { reveal(focus.wrappedValue, proxy) }
                    .onChange(of: focus.wrappedValue) { reveal(focus.wrappedValue, proxy) }
                }
            }
            Divider()
            tellGhost.listColumn()
        }
    }

    private var petName: String { SettingsAPI.live.config.pet.name }

    private func drop(_ id: String, on column: TaskColumn) {
        if TaskBoard.drop(id, on: column, tasks: tasks) == .needsName {
            holder = ""
            holdingTask = id
        }
    }

    private static func columns(_ tasks: [TaskItem], label: String?, query: String) -> [TaskColumn: [TaskItem]] {
        TaskBoard.columns(tasks, label: label, query: query)
    }

    /// A task shows when it has the chosen label and its title or notes contain the search text.
    func matches(_ task: TaskItem) -> Bool {
        Self.matches(task, label: labelFilter, query: search)
    }

    static func matches(_ task: TaskItem, label: String?, query: String) -> Bool {
        if let label, !task.labels.contains(where: { "\($0.key)=\($0.value)" == label }) { return false }
        return ListSearch.matches(query, in: [task.title, task.notes])
    }

    private var suggestionRows: [TaskSuggestion] {
        tasks.suggestions.filter { ListSearch.matches(search, in: [$0.title]) }
    }

    private var viewModePicker: some View {
        Picker("View", selection: $modeRaw) {
            ForEach(TaskViewMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Show tasks as a list or a board")
        .help("Show the tasks as a list or as a board of columns")
    }

    /// A menu of the labels in use, in the title row. Picking one shows only tasks with it; the chip clears it.
    @ViewBuilder private var labelFilterMenu: some View {
        let labels = tasks.allLabels
        if !labels.isEmpty || labelFilter != nil {
            HStack(spacing: 6) {
                Menu {
                    ForEach(labels.map { "\($0.key)=\($0.value)" }, id: \.self) { label in
                        Button(label) { labelFilter = label }
                    }
                } label: {
                    Label(labelFilter == nil ? "Filter by label" : "Label", systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Filter by label")
                if let labelFilter {
                    Button { self.labelFilter = nil } label: {
                        Label(labelFilter, systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .accessibilityLabel("Clear label filter \(labelFilter)")
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder private var suggestions: some View {
        if !suggestionRows.isEmpty {
            SectionHeader("Suggestions", action: "Add all", help: "Add every suggested new task. Updates to existing tasks are accepted one by one") { tasks.acceptAll() }
            ForEach(suggestionRows) { suggestion in
                SuggestionRow(suggestion: suggestion,
                              onAdd: { _ = try? tasks.accept(AcceptSuggestionRequest(id: suggestion.id)) },
                              onSkip: { tasks.skip(suggestion.id) },
                              onOpen: open(_:),
                              onShow: { suggestionNav.open(suggestion.id) })
            }
        }
    }

    @ViewBuilder private func doneSection(_ done: [TaskItem]) -> some View {
        if !done.isEmpty {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showDone.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("DONE (\(done.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showDone ? 90 : 0))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done, \(done.count) \(done.count == 1 ? "task" : "tasks")")
            .accessibilityValue(showDone ? "Expanded" : "Collapsed")
            .help(showDone ? "Hide finished tasks" : "Show tasks finished in the last 7 days")
            if showDone {
                ForEach(done) { row($0) }
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        TaskRow(task: task,
                onDone: { _ = try? tasks.close(CloseTaskRequest(id: task.id)) },
                onDelete: { try? tasks.delete(DeleteTaskRequest(id: task.id)) },
                onOpen: open(_:),
                onShow: { nav.open(task.id) })
            .background {
                if highlighted == task.id { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) }
            }
            .id(task.id)
    }

    /// Scrolls to the task a Today row opened and highlights it for a moment.
    private func reveal(_ id: String?, _ proxy: ScrollViewProxy?) {
        guard let id, let task = tasks.task(id) else { return }
        focus.wrappedValue = nil
        nav.close()
        if task.status == .done { showDone = true }
        highlighted = id
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy?.scrollTo(id, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlighted == id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { highlighted = nil } }
        }
    }

    private var tellGhost: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Tell \(petName)…", text: $message)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(send)
                .accessibilityLabel("Tell \(petName) about a task")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(10)
        .help("Tasks are changed through the chat, for example \"move the deploy task to in progress\"")
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        onTellGhost(text)
    }

    private func open(_ link: TaskLink) {
        switch TaskLinkRow(link: link).action {
        case .openURL(let url): NSWorkspace.shared.open(url)
        case .revealFile(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openThread(let ref): onOpenThread(ref)
        case .openSession(let ref): onOpenSession(ref)
        case .none: break
        }
    }
}

// MARK: - Rows

private struct TaskRow: View {
    let task: TaskItem
    let onDone: () -> Void
    let onDelete: () -> Void
    let onOpen: (TaskLink) -> Void
    let onShow: () -> Void

    private static let maxLinkButtons = 3
    private static let maxChips = 3

    var body: some View {
        ListRow(title: task.title, description: Self.firstLine(task.notes), dimmed: task.status == .done, onOpen: onShow,
                leading: { CheckButton(done: task.status == .done, title: task.title, action: onDone) },
                extra: { details },
                trailing: { _ in
                    HStack(spacing: 2) {
                        ForEach(Array(task.links.prefix(Self.maxLinkButtons).enumerated()), id: \.offset) { _, link in
                            IconButton(symbol: link.symbol, help: link.help) { onOpen(link) }
                        }
                    }
                })
        .contextMenu { menu }
        .accessibilityAction(named: "Delete", onDelete)
    }

    /// The first non-empty line of the notes, without markdown list or heading marks.
    static func firstLine(_ notes: String) -> String? { TaskItem.firstLine(of: notes) }

    private var details: some View {
        let now = Date()
        let overdue = task.isOverdue(now: now)
        return HStack(spacing: 5) {
            Image(systemName: task.source.symbol)
                .font(.system(size: 10))
                .accessibilityLabel("From \(task.source.rawValue)")
            Text(TaskTime.relative(task.closed ?? task.updated, now: now))
            if let waiting = task.waitingLabel {
                Text("·").accessibilityHidden(true)
                Label(waiting, systemImage: "person.badge.clock").labelStyle(DueLabelStyle())
            }
            if let due = task.dueLabel(now: now) {
                Text("·").accessibilityHidden(true)
                Label(due, systemImage: overdue ? "exclamationmark.circle.fill" : "calendar")
                    .labelStyle(DueLabelStyle())
                    .foregroundStyle(overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            ForEach(Array(task.labels.sorted { $0.key < $1.key }.prefix(Self.maxChips)), id: \.key) { key, value in
                Text("\(key)=\(value)")
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            if task.labels.count > Self.maxChips { Text("+\(task.labels.count - Self.maxChips)") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var menu: some View {
        if task.status != .done {
            Button("Mark Done", action: onDone)
        }
        ForEach(Array(task.links.enumerated()), id: \.offset) { _, link in
            Button(link.help) { onOpen(link) }
        }
        Button("Copy Title") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.title, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }
}

private struct SuggestionRow: View {
    let suggestion: TaskSuggestion
    let onAdd: () -> Void
    let onSkip: () -> Void
    let onOpen: (TaskLink) -> Void
    let onShow: () -> Void

    private var link: TaskLink? {
        suggestion.url.map { TaskLink(kind: .url, ref: $0.absoluteString, label: nil) }
    }

    var body: some View {
        ListRow(title: suggestion.title, description: nil, onOpen: onShow,
                leading: { ListRowIcon(symbol: "lightbulb") },
                extra: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: suggestion.source.symbol).font(.system(size: 10)).accessibilityHidden(true)
                            Text("\(suggestion.originLabel), \(TaskTime.relative(suggestion.created))")
                            if let waiting = suggestion.waitingLabel {
                                Text("·").accessibilityHidden(true)
                                Label(waiting, systemImage: "person.badge.clock").labelStyle(DueLabelStyle())
                            }
                            if let due = suggestion.due {
                                Text("·").accessibilityHidden(true)
                                Label("Due \(due)", systemImage: "calendar").labelStyle(DueLabelStyle())
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        HStack(spacing: 6) {
                            Button("Add", action: onAdd)
                                .help(suggestion.waitingOn == nil ? "Add to the backlog" : "Add to Waiting on others")
                            Button("Skip", action: onSkip)
                                .help("Dismiss this suggestion")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                    }
                },
                trailing: { _ in
                    if let link { IconButton(symbol: link.symbol, help: link.help) { onOpen(link) } }
                })
    }
}

// MARK: - Pieces

/// The leading circle. Shows a check on hover so it reads as a button before it is clicked.
private struct CheckButton: View {
    let done: Bool
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : hovering ? "checkmark.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(done ? AnyShapeStyle(AgentStatus.done.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .onHover { hovering = $0 }
        .padding(.top, 1)
        .help(done ? "Done" : "Mark done")
        .accessibilityLabel(done ? "Done: \(title)" : "Mark \(title) done")
    }
}

/// Icon and text on one baseline with a tight gap, for the metadata line.
private struct DueLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}
