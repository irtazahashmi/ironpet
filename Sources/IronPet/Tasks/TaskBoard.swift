import Foundation
import IronPetCore
import enum IronPetKit.QuickFilterNode

/// How the Tasks page shows its tasks. Saved in UserDefaults, so the choice survives a relaunch.
enum TaskViewMode: String, CaseIterable {
    case list, board, projects

    static let key = "tasksViewMode"

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    static func load(_ defaults: UserDefaults = .standard) -> TaskViewMode {
        defaults.string(forKey: key).flatMap(TaskViewMode.init(rawValue:)) ?? .list
    }

    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.key) }
}

/// The groups the list shows and the board draws as columns.
enum TaskColumn: String, CaseIterable, Identifiable {
    case needsYou, inProgress, backlog, waiting, someday, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYou: return TaskStatus.needsYou.title
        case .inProgress: return TaskStatus.inProgress.title
        case .backlog: return TaskStatus.backlog.title
        case .waiting: return "Waiting on others"
        case .someday: return TaskStatus.someday.title
        case .done: return TaskStatus.done.title
        }
    }

    /// The status a task gets when it is dropped here. Nil for Waiting on others, which keeps the status the task has.
    var status: TaskStatus? {
        switch self {
        case .needsYou: return .needsYou
        case .inProgress: return .inProgress
        case .backlog: return .backlog
        case .waiting: return nil
        case .someday: return .someday
        case .done: return .done
        }
    }

    /// The column a task is in. A task someone else holds is in Waiting on others whatever its status says, unless it is
    /// done or put off to someday.
    static func of(_ task: TaskItem) -> TaskColumn {
        if task.status == .done { return .done }
        if task.status == .someday { return .someday }
        if task.waitingOn != nil { return .waiting }
        switch task.status {
        case .needsYou: return .needsYou
        case .inProgress: return .inProgress
        case .backlog, .someday, .done: return .backlog
        }
    }
}

/// What a drop on a column asks the store to do.
enum TaskDropOutcome: Equatable {
    /// Nothing changes: the task is already in that column, or no longer exists.
    case unchanged
    /// The task changed.
    case moved
    /// Waiting on others needs the name of who holds the task. Call `TaskBoard.hold` with it.
    case needsName
}

enum TaskBoard {
    /// Done tasks stay in the database for `tasks.keepDoneDays`. The list and the board show the last week.
    static let doneWindow: TimeInterval = 7 * 86_400

    /// The tasks of each column, in the store's order, narrowed by the quick filter and the search text.
    /// The list and the board both read their groups from here, so they always agree.
    static func columns(_ tasks: [TaskItem], filter: QuickFilterNode?, query: String, now: Date = Date()) -> [TaskColumn: [TaskItem]] {
        let cutoff = now.addingTimeInterval(-doneWindow)
        var result: [TaskColumn: [TaskItem]] = [:]
        for task in tasks where !task.isDeferred(now: now) && TaskListView.matches(task, filter: filter, query: query, now: now) {
            let column = TaskColumn.of(task)
            if column == .done, (task.closed ?? task.updated) < cutoff { continue }
            result[column, default: []].append(task)
        }
        return result
    }

    /// The tasks put off to a later day (the tickler), soonest first, narrowed like the columns. They are in no column until then.
    static func deferred(_ tasks: [TaskItem], filter: QuickFilterNode?, query: String, now: Date = Date()) -> [TaskItem] {
        tasks.filter { $0.isDeferred(now: now) && TaskListView.matches($0, filter: filter, query: query, now: now) }
            .sorted { ($0.deferUntil ?? .distantFuture) < ($1.deferUntil ?? .distantFuture) }
    }

    /// Applies a card dropped on `column`.
    /// - Waiting on others: returns `.needsName`. A done task is reopened to the backlog once it has a name, so it leaves Done.
    /// - Done: closes the task as the check button does.
    /// - Any other column: sets the status and clears who the task waits on.
    @MainActor
    static func drop(_ id: String, on column: TaskColumn, tasks: TasksAPI) -> TaskDropOutcome {
        guard let task = tasks.task(id), TaskColumn.of(task) != column else { return .unchanged }
        switch column {
        case .waiting:
            return .needsName
        case .done:
            if task.waitingOn != nil { _ = try? tasks.update(UpdateTaskRequest(id: id, waitingOn: "")) }
            return (try? tasks.close(CloseTaskRequest(id: id))) == nil ? .unchanged : .moved
        case .needsYou, .inProgress, .backlog, .someday:
            var request = UpdateTaskRequest(id: id, status: column.status)
            if task.waitingOn != nil { request.waitingOn = "" }
            return (try? tasks.update(request)) == nil ? .unchanged : .moved
        }
    }

    /// Records that `name` holds the task. The status stays, except that a done task goes back to the backlog.
    @MainActor
    @discardableResult
    static func hold(_ id: String, name: String, tasks: TasksAPI) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let task = tasks.task(id) else { return false }
        var request = UpdateTaskRequest(id: id, waitingOn: name)
        if task.status == .done { request.status = .backlog }
        return (try? tasks.update(request)) != nil
    }
}

extension TaskItem {
    /// The first non-empty line of the notes, without markdown list or heading marks.
    static func firstLine(of notes: String) -> String? {
        notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-*> ").union(.whitespaces)) }
            .first { !$0.isEmpty }
    }
}
