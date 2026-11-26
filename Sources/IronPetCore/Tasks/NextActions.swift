import Foundation
import IronPetKit

/// One heading of the Next actions list: the tasks that can be done in one context, in the list's order.
package struct NextActionGroup: Identifiable, Equatable {
    /// Nil for the tasks that name no context.
    package let context: TaskContext?
    package let tasks: [TaskItem]

    package var id: String { context?.rawValue ?? "none" }
    package var title: String { context?.title ?? "No context" }
}

package enum NextActions {
    /// The contexts in the order the list shows them, then the tasks with none. Empty groups are left out.
    package static func groups(_ tasks: [TaskItem]) -> [NextActionGroup] {
        var buckets: [TaskContext?: [TaskItem]] = [:]
        for task in tasks { buckets[TaskContext.of(task.labels), default: []].append(task) }
        let order: [TaskContext?] = TaskContext.allCases.map { $0 } + [nil]
        return order.compactMap { context in
            buckets[context].map { NextActionGroup(context: context, tasks: $0) }
        }
    }
}
