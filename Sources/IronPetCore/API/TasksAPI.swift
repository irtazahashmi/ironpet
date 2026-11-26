import Foundation
import IronPetKit
#if canImport(Combine)
import Combine
#endif

package struct TaskListRequest: Codable, Equatable {
    package init(statuses: [TaskStatus]? = nil, includeDone: Bool = false, labels: [String: String] = [:], assignee: String? = nil) {
        self.statuses = statuses
        self.includeDone = includeDone
        self.labels = labels
        self.assignee = assignee
    }

    /// Only tasks in these statuses. Nil lists every open task.
    package var statuses: [TaskStatus]?
    /// Adds done tasks when `statuses` is nil.
    package var includeDone = false
    /// Only tasks that have all of these labels with these values.
    package var labels: [String: String] = [:]
    /// Only tasks assigned to this agent id. An empty string or `user` lists the tasks nobody but the user works on. Nil lists every task.
    package var assignee: String?
}

package struct TaskWithHistory: Codable, Equatable {
    package init(task: TaskItem, history: [TaskEvent]) {
        self.task = task
        self.history = history
    }

    package var task: TaskItem
    package var history: [TaskEvent]
}

package struct CreateTaskRequest: Codable, Equatable {
    package init(
        title: String,
        notes: String = "",
        status: TaskStatus = .backlog,
        source: TaskSource,
        due: Date? = nil,
        links: [TaskLink] = [],
        waitingOn: String? = nil,
        sourceRef: String? = nil,
        labels: [String: String] = [:],
        deferUntil: Date? = nil,
        assignee: String? = nil,
        by: String = "user"
    ) {
        self.title = title
        self.notes = notes
        self.status = status
        self.source = source
        self.due = due
        self.links = links
        self.waitingOn = waitingOn
        self.sourceRef = sourceRef
        self.labels = labels
        self.deferUntil = deferUntil
        self.assignee = assignee
        self.by = by
    }

    package var title: String
    package var notes = ""
    package var status: TaskStatus = .backlog
    package var source: TaskSource
    package var due: Date?
    package var links: [TaskLink] = []
    package var waitingOn: String?
    package var sourceRef: String?
    /// Key/value labels, such as `merge=auto`. Data for filtering, never instructions.
    package var labels: [String: String] = [:]
    /// Keeps the task out of the list until then.
    package var deferUntil: Date?
    /// The agent the task is assigned to. Nil, an empty string and `user` leave it with the user.
    package var assignee: String?
    /// Who is asking: `user`, `agent:mcp`, `agent:cli`. It goes to the task's history.
    package var by = "user"
}

/// A nil field keeps the task's value.
package struct UpdateTaskRequest: Codable, Equatable {
    package init(
        id: String,
        title: String? = nil,
        notes: String? = nil,
        status: TaskStatus? = nil,
        due: Date? = nil,
        clearDue: Bool = false,
        links: [TaskLink]? = nil,
        waitingOn: String? = nil,
        labels: [String: String] = [:],
        removeLabels: [String] = [],
        deferUntil: Date? = nil,
        clearDeferUntil: Bool = false,
        assignee: String? = nil,
        note: String? = nil,
        by: String = "user"
    ) {
        self.deferUntil = deferUntil
        self.clearDeferUntil = clearDeferUntil ? true : nil
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.due = due
        self.clearDue = clearDue
        self.links = links
        self.waitingOn = waitingOn
        self.labels = labels
        self.removeLabels = removeLabels
        self.assignee = assignee
        self.note = note
        self.by = by
    }

    package var id: String
    package var title: String?
    package var notes: String?
    package var status: TaskStatus?
    package var due: Date?
    /// Removes the due date. `due` is ignored when this is set.
    package var clearDue = false
    package var links: [TaskLink]?
    /// A blank name clears who the task waits on.
    package var waitingOn: String?
    /// Labels to add or overwrite. Other labels stay.
    package var labels: [String: String] = [:]
    /// Label keys to remove.
    package var removeLabels: [String] = []
    package var deferUntil: Date?
    /// Shows the task again now. `deferUntil` is ignored when this is true. Optional, so a request from a client that
    /// predates it still decodes.
    package var clearDeferUntil: Bool?
    /// A new assignee: an agent id. An empty string or `user` hands the task back to the user. Nil keeps the assignee.
    package var assignee: String?
    /// Goes to the history only, to say why something changed.
    package var note: String?
    package var by = "user"
}

package struct CloseTaskRequest: Codable, Equatable {
    package init(id: String, note: String? = nil, by: String = "user") {
        self.id = id
        self.note = note
        self.by = by
    }

    package var id: String
    package var note: String?
    package var by = "user"
}

package struct DeleteTaskRequest: Codable, Equatable {
    package init(id: String, by: String = "user") {
        self.id = id
        self.by = by
    }

    package var id: String
    package var by = "user"
}

/// A task an agent proposes. It waits as a suggestion for the user to add or skip.
package struct SuggestTaskRequest: Codable, Equatable {
    package init(draft: TaskSuggestion.Draft, kind: TaskSource, sourceRef: String) {
        self.draft = draft
        self.kind = kind
        self.sourceRef = sourceRef
    }

    package var draft: TaskSuggestion.Draft
    package var kind: TaskSource
    package var sourceRef: String
}

package struct AcceptSuggestionRequest: Codable, Equatable {
    package init(
        id: String,
        title: String? = nil,
        due: Date? = nil,
        notes: String? = nil,
        status: TaskStatus? = nil,
        note: String? = nil,
        by: String = "user"
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.notes = notes
        self.status = status
        self.note = note
        self.by = by
    }

    package var id: String
    package var title: String?
    package var due: Date?
    package var notes: String?
    package var status: TaskStatus?
    package var note: String?
    package var by = "user"
}

package struct RejectSuggestionRequest: Codable, Equatable {
    package init(id: String, note: String? = nil, by: String = "user") {
        self.id = id
        self.note = note
        self.by = by
    }

    package var id: String
    package var note: String?
    package var by = "user"
}

/// Tasks and the suggestions waiting for review. The one way a client reads or changes them.
///
/// This is an `ObservableObject` on Apple platforms, so a SwiftUI view can redraw when the list changes. The list itself is read through the
/// properties and calls below, never from the store.
@MainActor
package final class TasksAPI {
    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    private let store: TaskStore
    /// Where quick filters are saved (`tasks.quickFilters` in `config.json`). Nil keeps them in memory, as tests and previews do.
    private let config: ConfigStore?
    private var memoryFilters: [QuickFilter] = []
    private var forwarding: [ChangeToken] = []

    package init(store: TaskStore, config: ConfigStore? = nil) {
        self.store = store
        self.config = config
        // Filters live in config, so they get their refs here, where agents first see the list. Old filter ids then resolve through `get`.
        _ = store.records.refs(.filter, (config?.config.tasks.quickFilters ?? []).map(\.id))
        forwarding = [
            store.changes.observe { [weak self] in self?.changes.send() },
        ]
        if let config {
            forwarding.append(config.changes.observe { [weak self] in self?.changes.send() })
        }
    }

    var quickFilterStorage: [QuickFilter] { config?.config.tasks.quickFilters ?? memoryFilters }

    /// The public id of a record kept with the tasks (a task or a filter), created on first use.
    package func ref(_ kind: RecordKind, _ key: String) -> String? { store.records.ref(kind, key) }

    func setQuickFilterStorage(_ filters: [QuickFilter]) {
        guard let config else {
            changes.send()
            memoryFilters = filters
            return
        }
        config.update { $0.tasks.quickFilters = filters }
    }

    // MARK: Reading

    /// Every task in the store's order: open ones first (needs you, in progress, backlog), then done.
    package var all: [TaskItem] { store.ordered }
    /// Every task in storage order, for readers that sort for themselves.
    package var items: [TaskItem] { store.tasks }
    package var suggestions: [TaskSuggestion] { store.suggestions }
    /// What the Tasks section counts: tasks that need the user or are moving, not ones waiting on someone else.
    package var activeCount: Int { store.activeCount }
    /// Every label in use, sorted, for a filter.
    package var allLabels: [(key: String, value: String)] { store.allLabels }
    /// Why tasks are only in memory, when the database could not be opened.
    package var unavailable: String? { store.unavailable }

    /// The agents an assignee can name, to show their names. Empty on a host with no agent registry.
    package var agents: [AgentRecord] { store.registry?.list() ?? [] }

    package func task(_ id: String) -> TaskItem? { store.task(id) }
    package func history(_ id: String) -> [TaskEvent] { store.history(id) }

    package func list(_ request: TaskListRequest = TaskListRequest()) -> [TaskItem] {
        var matching = store.ordered.filter { item in request.labels.allSatisfy { item.labels[$0.key] == $0.value } }
        if let wanted = request.assignee { matching = matching.filter { $0.assignee == TaskAssignee.normalize(wanted) } }
        if let statuses = request.statuses { return matching.filter { statuses.contains($0.status) } }
        return request.includeDone ? matching : matching.filter { $0.status != .done }
    }

    package func get(_ id: String) throws -> TaskWithHistory {
        guard let task = store.task(id) else { throw APIError.notFound("no task with id \"\(id)\"") }
        return TaskWithHistory(task: task, history: store.history(id))
    }

    // MARK: Changing

    @discardableResult
    package func create(_ request: CreateTaskRequest) throws -> TaskItem {
        try run {
            try store.create(title: request.title, notes: request.notes, status: request.status, source: request.source, due: request.due,
                             links: request.links, waitingOn: request.waitingOn, sourceRef: request.sourceRef, labels: request.labels,
                             deferUntil: request.deferUntil, assignee: request.assignee, by: request.by)
        }
    }

    @discardableResult
    package func update(_ request: UpdateTaskRequest) throws -> TaskItem {
        try run {
            try store.update(request.id, title: request.title, notes: request.notes, status: request.status,
                             due: request.clearDue ? .some(nil) : request.due.map { .some($0) },
                             links: request.links, waitingOn: request.waitingOn.map { .some($0) }, addLabels: request.labels,
                             removeLabels: request.removeLabels,
                             deferUntil: request.clearDeferUntil == true ? .some(nil) : request.deferUntil.map { .some($0) },
                             assignee: request.assignee.map { .some($0) }, note: request.note, by: request.by)
        }
    }

    @discardableResult
    package func close(_ request: CloseTaskRequest) throws -> TaskItem {
        try run { try store.close(request.id, note: request.note, by: request.by) }
    }

    package func delete(_ request: DeleteTaskRequest) throws {
        try run { try store.delete(request.id, by: request.by) }
    }

    // MARK: Suggestions

    /// The suggestion that was added, or none when it was a repeat or the title is already a task or a suggestion.
    @discardableResult
    package func suggest(_ request: SuggestTaskRequest) -> [TaskSuggestion] {
        store.suggest(request.draft, agent: request.kind, sourceRef: request.sourceRef)
    }

    @discardableResult
    package func accept(_ request: AcceptSuggestionRequest) throws -> TaskItem {
        try run {
            var overrides = TaskStore.Overrides(title: request.title, due: nil, notes: request.notes, status: request.status?.rawValue)
            overrides.due = request.due.map { ISO8601DateFormatter().string(from: $0) }
            return try store.accept(request.id, overrides: overrides, note: request.note, by: request.by)
        }
    }

    /// Adds every suggestion as a task.
    package func acceptAll() { store.acceptAll() }

    package func reject(_ request: RejectSuggestionRequest) throws {
        try run { try store.reject(request.id, note: request.note, by: request.by) }
    }

    /// Drops a suggestion without a reason, as the Skip button does.
    package func skip(_ id: String) { store.skip(id) }

    // MARK: Errors

    private func run<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TaskError {
            let missing = error.message.hasPrefix("no task") || error.message.hasPrefix("no suggestion") || error.message.hasPrefix("no agent")
            throw missing ? APIError.notFound(error.message) : APIError.invalid(error.message)
        } catch {
            throw APIError.wrap(error)
        }
    }
}

#if canImport(Combine)

extension TasksAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
