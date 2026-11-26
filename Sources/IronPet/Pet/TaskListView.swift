import AppKit
import enum IronPetKit.SharedTheme
import enum IronPetKit.SharedSymbols
import IronPetCore
import enum IronPetKit.BuiltInQuickFilters
import struct IronPetKit.QuickFilter
import enum IronPetKit.QuickFilterPrompt
import enum IronPetKit.QuickFilterNode
import enum IronPetKit.QuickFilterSelection
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
    @State private var showSomeday = false
    @State private var showDeferred = false
    @State private var message = ""
    @State private var highlighted: String?
    /// The id of the quick filter the list is narrowed by. Empty is the "All" chip. Saved per device, so it survives
    /// switching sections and a relaunch.
    @AppStorage(QuickFilterSelection.key) private var selectedFilterRaw = ""
    /// The Add or Edit sheet, until the user sends or cancels.
    @State private var filterRequest: QuickFilterRequest?
    /// The filter the user asked to remove, until they confirm.
    @State private var removingFilter: QuickFilter?
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
        ListScreen(title: IronPetSection.tasks.title, search: $search, detailOpen: nav.opened != nil || suggestionNav.opened != nil, trailing: { viewModePicker }) {
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
            .sheet(item: $filterRequest) { request in
                QuickFilterRequestSheet(request: request, petName: petName) { text in
                    onTellGhost(request.prompt(text))
                    filterRequest = nil
                } onCancel: { filterRequest = nil }
            }
            .confirmationDialog("Remove the quick filter \"\(removingFilter?.name ?? "")\"?", isPresented: removingShown, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let filter = removingFilter { remove(filter) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tasks are not changed.")
            }
            .onAppear(perform: dropStaleFilter)
            .onChange(of: tasks.quickFilters.map(\.id)) { dropStaleFilter() }
            .alert("Waiting on whom?", isPresented: holdingAlertShown) {
                TextField("Name", text: $holder)
                Button("Cancel", role: .cancel) {}
                Button("Set") { if let id = holdingTask { TaskBoard.hold(id, name: holder, tasks: tasks) } }
            } message: {
                Text("The task moves to Waiting on others.")
            }
        }
    }

    private var selectedFilter: String? {
        get { selectedFilterRaw.isEmpty ? nil : selectedFilterRaw }
        nonmutating set { selectedFilterRaw = newValue ?? "" }
    }

    /// Clears a saved filter that was deleted while the app was closed, so the list shows All and the stored value goes.
    private func dropStaleFilter() {
        if selectedFilter != nil, QuickFilterSelection.valid(selectedFilter, in: shownChips) == nil { selectedFilter = nil }
    }

    /// The built-in chips first, then the saved ones, in the order the bar shows them.
    private var shownChips: [QuickFilter] { tasks.builtInQuickFilters + QuickFilter.chips(tasks.quickFilters) }

    private var isNextActions: Bool { tasks.groupsByContext(selectedFilter) }

    private var removingShown: Binding<Bool> {
        Binding(get: { removingFilter != nil }, set: { if !$0 { removingFilter = nil } })
    }

    /// The chosen filter's query, or nil for "All". A filter that was removed or that this build cannot read counts as "All".
    private var activeFilter: QuickFilterNode? {
        selectedFilter.flatMap { tasks.quickFilter($0)?.node }
    }

    /// The chip to highlight. A filter the agent removed meanwhile leaves "All" highlighted, which is what the list shows.
    private var shownFilter: Binding<String?> {
        Binding(get: { selectedFilter.flatMap { id in shownChips.contains { $0.id == id } ? id : nil } },
                set: { selectedFilter = $0 })
    }

    private func remove(_ filter: QuickFilter) {
        try? tasks.deleteQuickFilter(filter.id)
        if selectedFilter == filter.id { selectedFilter = nil }
    }

    private var holdingAlertShown: Binding<Bool> {
        Binding(get: { holdingTask != nil }, set: { if !$0 { holdingTask = nil } })
    }

    private var isDetailOpen: Bool { nav.opened != nil || suggestionNav.opened != nil }

    @ViewBuilder private func suggestionPage(_ id: String) -> some View {
        if let suggestion = tasks.suggestions.first(where: { $0.id == id }) {
            ListDetailPage(section: "Tasks", onBack: { suggestionNav.close() }) {
                Text(suggestion.headline).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Button(suggestion.update == nil ? "Add" : "Accept") { _ = try? tasks.accept(AcceptSuggestionRequest(id: suggestion.id)); suggestionNav.close() }
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
            let columns = Self.columns(tasks.all, filter: activeFilter, query: search)
            if content == .list || !tasks.quickFilters.isEmpty {
                QuickFilterBar(filters: QuickFilter.chips(tasks.quickFilters), builtIn: tasks.builtInQuickFilters, selection: shownFilter,
                               onAdd: { filterRequest = .add },
                               onEdit: { filterRequest = .edit($0) },
                               onRemove: { removingFilter = $0 },
                               onMove: { filter, step in try? tasks.moveQuickFilter(filter.id, by: step) })
                Divider()
            }
            let nothingShown = suggestionRows.isEmpty && columns.isEmpty
                && (mode == .board || isNextActions || TaskBoard.deferred(tasks.all, filter: activeFilter, query: search).isEmpty)
            if content == .unavailable {
                Spacer()
            } else if content == .empty {
                EmptyState(symbol: SharedSymbols.tasks, title: "No tasks yet",
                           detail: "Ask \(petName) to keep track of something, or finish a meeting.")
            } else if nothingShown {
                NoMatches()
            } else if mode == .board {
                if !suggestionRows.isEmpty {
                    ListScroll { suggestions }.frame(maxHeight: 190)
                    Divider()
                }
                TaskBoardView(columns: columns, agents: tasks.agents, highlighted: highlighted, onOpen: { nav.open($0) },
                              onDrop: drop(_:on:))
                    .onAppear { reveal(focus.wrappedValue, nil) }
                    .onChange(of: focus.wrappedValue) { reveal(focus.wrappedValue, nil) }
            } else {
                ScrollViewReader { proxy in
                    ListScroll {
                        suggestions
                        if isNextActions {
                            nextActionGroups(columns)
                        } else {
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
                            collapsible(TaskColumn.someday.title, columns[.someday] ?? [], open: $showSomeday,
                                        show: "Show tasks put off to someday", hide: "Hide someday tasks")
                            collapsible("Deferred", TaskBoard.deferred(tasks.all, filter: activeFilter, query: search), open: $showDeferred,
                                        show: "Show tasks hidden until a later day", hide: "Hide deferred tasks")
                            doneSection(columns[.done] ?? [])
                        }
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

    private static func columns(_ tasks: [TaskItem], filter: QuickFilterNode?, query: String) -> [TaskColumn: [TaskItem]] {
        TaskBoard.columns(tasks, filter: filter, query: query)
    }

    /// A task shows when it matches the chosen quick filter and its title or notes contain the search text.
    func matches(_ task: TaskItem) -> Bool {
        Self.matches(task, filter: activeFilter, query: search)
    }

    static func matches(_ task: TaskItem, filter: QuickFilterNode?, query: String, now: Date = Date()) -> Bool {
        if let filter, !filter.matches(task, now: now) { return false }
        return ListSearch.matches(query, in: [task.title, task.notes])
    }

    private var suggestionRows: [TaskSuggestion] {
        tasks.suggestions.filter { ListSearch.matches(search, in: [$0.title, $0.headline, $0.update?.summary ?? ""]) }
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

    @ViewBuilder private var suggestions: some View {
        if !suggestionRows.isEmpty {
            SectionHeader("Inbox", action: "Add all", help: "Add every suggested new task. Updates to existing tasks are accepted one by one") { tasks.acceptAll() }
            ForEach(suggestionRows) { suggestion in
                SuggestionRow(suggestion: suggestion,
                              onAdd: { _ = try? tasks.accept(AcceptSuggestionRequest(id: suggestion.id)) },
                              onSkip: { tasks.skip(suggestion.id) },
                              onOpen: open(_:),
                              onShow: { suggestionNav.open(suggestion.id) })
            }
        }
    }

    /// The Next actions list: the open tasks under a heading for each context. The chip already leaves out done and waiting tasks.
    @ViewBuilder private func nextActionGroups(_ columns: [TaskColumn: [TaskItem]]) -> some View {
        let open = [TaskColumn.needsYou, .inProgress, .backlog].flatMap { columns[$0] ?? [] }
        ForEach(NextActions.groups(open)) { group in
            ListGroupTitle(group.title)
            ForEach(group.tasks) { row($0) }
        }
    }

    @ViewBuilder private func doneSection(_ done: [TaskItem]) -> some View {
        collapsible("Done", done, open: $showDone, show: "Show tasks finished in the last 7 days", hide: "Hide finished tasks")
    }

    /// A group that starts closed: Someday, Deferred and Done, which the user looks at in a review rather than every day.
    @ViewBuilder private func collapsible(_ title: String, _ items: [TaskItem], open: Binding<Bool>, show: String, hide: String) -> some View {
        if !items.isEmpty {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { open.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("\(title.uppercased()) (\(items.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                    Image(systemName: SharedSymbols.chevron)
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(items.count) \(items.count == 1 ? "task" : "tasks")")
            .accessibilityValue(open.wrappedValue ? "Expanded" : "Collapsed")
            .help(open.wrappedValue ? hide : show)
            if open.wrappedValue {
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        TaskRow(task: task, agents: tasks.agents,
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
        if task.status == .someday {
            showSomeday = true
            if isNextActions { nav.open(id) }
        }
        if task.isDeferred() {
            showDeferred = true
            // The board and Next actions draw no Deferred group, so the task's page is the only place to show it.
            if mode == .board || isNextActions { nav.open(id) }
        }
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
        .background(RoundedRectangle(cornerRadius: 8).fill(SharedTheme.card))
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
    let agents: [AgentRecord]
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
            Text("·").accessibilityHidden(true)
            Label(TaskAssignee.name(task.assignee, agents: agents), systemImage: task.assignee == nil ? "person" : "sparkles")
                .labelStyle(DueLabelStyle())
                .accessibilityLabel("Assigned to \(TaskAssignee.name(task.assignee, agents: agents))")
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
        ListRow(title: suggestion.headline, description: suggestion.update?.summary, onOpen: onShow,
                leading: { ListRowIcon(symbol: suggestion.update == nil ? "lightbulb" : "arrow.triangle.2.circlepath") },
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
                        if let clarify = suggestion.clarify {
                            Label("Files as: \(clarify.summary)", systemImage: "sparkles")
                                .labelStyle(DueLabelStyle())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Button(suggestion.update == nil ? "Add" : "Accept", action: onAdd)
                                .help(suggestion.update != nil ? "Apply this change to the task"
                                      : suggestion.clarify.map { "Add as proposed: \($0.summary)" } ??
                                      (suggestion.waitingOn == nil ? "Add to the backlog" : "Add to Waiting on others"))
                            Button("Skip", action: onSkip)
                                .help(suggestion.update == nil ? "Dismiss this suggestion" : "Leave the task as it is")
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
            Image(systemName: done ? SharedSymbols.done : hovering ? "checkmark.circle" : "circle")
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
