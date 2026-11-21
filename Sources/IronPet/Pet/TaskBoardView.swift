import SwiftUI

/// The tasks as five columns. A card opens the task, and dropping it on another column changes its status.
struct TaskBoardView: View {
    let columns: [TaskColumn: [TaskItem]]
    var highlighted: String?
    let onOpen: (String) -> Void
    let onDrop: (String, TaskColumn) -> Void

    static let columnWidth: CGFloat = 230

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(TaskColumn.allCases) { column in
                    BoardColumn(column: column, tasks: columns[column] ?? [], highlighted: highlighted, onOpen: onOpen, onDrop: onDrop)
                }
            }
            .padding(.horizontal, ListScreenMetrics.gutter)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("task-board")
    }
}

private struct BoardColumn: View {
    let column: TaskColumn
    let tasks: [TaskItem]
    let highlighted: String?
    let onOpen: (String) -> Void
    let onDrop: (String, TaskColumn) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(column.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                Text("\(tasks.count)").font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(tasks) { task in
                        BoardCard(task: task, highlighted: highlighted == task.id, onOpen: onOpen, onDrop: onDrop)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(8)
        .frame(width: TaskBoardView.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(targeted ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: targeted ? 2 : 1))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { onDrop(id, column) }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(column.title)
        .accessibilityIdentifier("board-column-\(column.rawValue)")
    }
}

private struct BoardCard: View {
    let task: TaskItem
    let highlighted: Bool
    let onOpen: (String) -> Void
    let onDrop: (String, TaskColumn) -> Void

    var body: some View {
        let now = Date()
        let overdue = task.isOverdue(now: now)
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .strikethrough(task.status == .done)
                .foregroundStyle(task.status == .done ? .secondary : .primary)
                .lineLimit(3)
            if let line = TaskItem.firstLine(of: task.notes) {
                Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            if task.waitingLabel != nil || task.dueLabel(now: now) != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let waiting = task.waitingLabel {
                        Label(waiting, systemImage: "person.badge.clock")
                    }
                    if let due = task.dueLabel(now: now) {
                        Label(due, systemImage: overdue ? "exclamationmark.circle.fill" : "calendar")
                            .foregroundStyle(overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(highlighted ? 0.16 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onOpen(task.id) }
        .draggable(task.id)
        .contextMenu {
            Menu("Move to") {
                ForEach(TaskColumn.allCases.filter { $0 != TaskColumn.of(task) }) { column in
                    Button(column.title) { onDrop(task.id, column) }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("board-card-\(task.id)")
        .accessibilityAction(named: "Open") { onOpen(task.id) }
        .accessibilityActions {
            ForEach(TaskColumn.allCases.filter { $0 != TaskColumn.of(task) }) { column in
                Button("Move to \(column.title)") { onDrop(task.id, column) }
            }
        }
    }
}
