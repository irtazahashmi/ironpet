import Foundation

extension TaskItem {
    package func isOverdue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let due, status != .done else { return false }
        return TaskDue.isAllDay(due, calendar: calendar) ? due < calendar.startOfDay(for: now) : due < now
    }

    /// "Due tomorrow", "Due Nov 20 at 15:30", "Overdue since yesterday". Nil without a due date.
    package func dueLabel(now: Date, calendar: Calendar = .current) -> String? {
        guard let due else { return nil }
        var dayFormat = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if !calendar.isDate(due, equalTo: now, toGranularity: .year) { dayFormat = dayFormat.year() }
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        let today = calendar.startOfDay(for: now)
        let day: String
        switch calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day {
        case 0: day = "today"
        case 1: day = "tomorrow"
        case -1: day = "yesterday"
        default: day = due.formatted(dayFormat)
        }
        var timeFormat = Date.FormatStyle.dateTime.hour().minute()
        timeFormat.calendar = calendar
        timeFormat.timeZone = calendar.timeZone
        let time = TaskDue.isAllDay(due, calendar: calendar) ? nil : due.formatted(timeFormat)
        if isOverdue(now: now, calendar: calendar) {
            if day == "today", let time { return "Overdue since \(time)" }
            return "Overdue since \(day)" + (time.map { " \($0)" } ?? "")
        }
        return "Due \(day)" + (time.map { " at \($0)" } ?? "")
    }
}
