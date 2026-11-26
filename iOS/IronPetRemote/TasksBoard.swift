import Foundation
import IronPetKit

/// How the Tasks tab shows its tasks. `@AppStorage` keeps the choice on this phone.
enum TasksViewMode: String, CaseIterable {
    case list, board

    static let key = "tasksViewMode"

    var title: String { self == .list ? "List" : "Board" }
}

/// The five groups of the Mac's list, drawn as board columns.
enum BoardColumn: String, CaseIterable, Identifiable {
    case needsYou = "needs-you", inProgress = "in-progress", backlog, waiting, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYou: return TaskStatus.needsYou.title
        case .inProgress: return TaskStatus.inProgress.title
        case .backlog: return TaskStatus.backlog.title
        case .waiting: return "Waiting on others"
        case .done: return TaskStatus.done.title
        }
    }

    /// The status a task gets when dropped here. Nil for Waiting on others, which keeps the task's status.
    var status: TaskStatus? {
        switch self {
        case .needsYou: return .needsYou
        case .inProgress: return .inProgress
        case .backlog: return .backlog
        case .waiting: return nil
        case .done: return .done
        }
    }

    static func of(_ task: RemoteTask) -> BoardColumn {
        if task.status == .done { return .done }
        if task.waitingOn != nil { return .waiting }
        switch task.status {
        case .needsYou: return .needsYou
        case .inProgress: return .inProgress
        // The Mac sends someday tasks only when asked (`include_someday`), which this phone does not do yet.
        case .backlog, .someday, .done: return .backlog
        }
    }
}

enum BoardDropOutcome: Equatable {
    /// Nothing changed: the task is already in that column, is unknown, or the Mac refused the update.
    case unchanged
    case moved
    /// Waiting on others needs a name. Call `TasksModel.hold` with it.
    case needsName
}

extension TasksModel {
    /// Done tasks shown on the board, as on the Mac: the ones closed in the last week.
    static let doneWindow: TimeInterval = 7 * 86_400

    static func boardColumns(_ tasks: [RemoteTask], now: Date = Date()) -> [BoardColumn: [RemoteTask]] {
        let cutoff = now.addingTimeInterval(-doneWindow)
        var result: [BoardColumn: [RemoteTask]] = [:]
        for task in tasks {
            let column = BoardColumn.of(task)
            if column == .done, (task.closed ?? task.updated) < cutoff { continue }
            result[column, default: []].append(task)
        }
        return result
    }

    var boardColumns: [BoardColumn: [RemoteTask]] { Self.boardColumns(visibleTasks) }

    /// A card was dropped on `column`. Each case is one request, except a waiting task closed from the board, which clears who it
    /// waits on first. The update calls are the ones the detail page uses.
    func drop(_ id: String, on column: BoardColumn) async -> BoardDropOutcome {
        guard let task = tasks.first(where: { $0.id == id }), BoardColumn.of(task) != column else { return .unchanged }
        switch column {
        case .waiting:
            return .needsName
        case .done:
            if task.waitingOn != nil, await run({ try await self.client.setWaitingOn(id: id, name: nil) }) == nil { return .unchanged }
            return await close(id, note: "Closed from the board on the iPhone.") ? .moved : .unchanged
        case .needsYou, .inProgress, .backlog:
            guard let status = column.status else { return .unchanged }
            if task.waitingOn != nil {
                let moved = await run { try await self.client.setWaitingOn(id: id, name: nil, status: status) } != nil
                if moved { await reloadTasks() }
                return moved ? .moved : .unchanged
            }
            return await setStatus(id, status: status, note: "") ? .moved : .unchanged
        }
    }

    /// Records who holds the task. A done task goes back to the backlog, so it leaves Done.
    func hold(_ id: String, name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let task = tasks.first(where: { $0.id == id }) else { return false }
        let moved = await run { try await self.client.setWaitingOn(id: id, name: name, status: task.status == .done ? .backlog : nil) } != nil
        if moved { await reloadTasks() }
        return moved
    }
}
