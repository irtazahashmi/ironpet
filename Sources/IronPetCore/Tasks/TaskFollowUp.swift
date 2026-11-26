import Foundation

/// GTD's waiting-for list: when the user asked someone, and when it is time to follow up.
package enum TaskFollowUp {
    /// Working days (Monday to Friday) to wait before a follow-up is due.
    package static let workingDays = 5

    /// Working days from the day after `start` up to and including the day of `end`, counted up to `limit`.
    package static func workingDays(from start: Date, to end: Date, calendar: Calendar, limit: Int = workingDays) -> Int {
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var count = 0
        while day < last, count < limit, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            day = next
            if !calendar.isDateInWeekend(day) { count += 1 }
        }
        return count
    }
}

extension TaskItem {
    /// Waiting on someone for at least `TaskFollowUp.workingDays` working days since the user asked.
    package func followUpDue(now: Date, calendar: Calendar = .current) -> Bool {
        guard status != .done, waitingOn != nil, let askedAt else { return false }
        return TaskFollowUp.workingDays(from: askedAt, to: now, calendar: calendar) >= TaskFollowUp.workingDays
    }
}
