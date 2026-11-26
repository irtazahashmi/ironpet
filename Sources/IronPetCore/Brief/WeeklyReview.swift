import Foundation

/// How much of the work the user finished served one of their goals: closed tasks whose project serves an active goal,
/// out of all closed tasks in a window.
package enum GoalAlignment {
    package struct Score: Equatable {
        package let aligned: Int
        package let total: Int
        package var percent: Int { total == 0 ? 0 : Int((Double(aligned) / Double(total) * 100).rounded()) }
        /// `Goal alignment: 60%`
        package var title: String { "Goal alignment: \(percent)%" }
        /// `3 of 5 closed tasks served a goal`
        package var detail: String { "\(aligned) of \(total) closed \(total == 1 ? "task" : "tasks") served a goal" }
    }

    /// Nil without an active goal (there is nothing to align to) or without a task closed in the window.
    package static func score(_ input: BriefInput, in window: DateInterval) -> Score? {
        let active = Set(input.goals.filter { $0.status == .active }.map(\.id))
        guard !active.isEmpty else { return nil }
        let serving = Set(input.projects.filter { $0.goal.map(active.contains) ?? false }.map(\.id))
        let closed = input.tasks.filter { $0.status == .done && ($0.closed.map(window.contains) ?? false) }
        guard !closed.isEmpty else { return nil }
        return Score(aligned: closed.filter { $0.project.map(serving.contains) ?? false }.count, total: closed.count)
    }

    /// The section the brief, the recap and the review show it in.
    static func section(_ score: Score?) -> Brief.Section? {
        score.map { Brief.Section(id: "alignment", title: "Goals", items: [
            Brief.Item(id: "alignment", symbol: "target", title: $0.title, subtitle: $0.detail, target: .task("")),
        ]) }
    }
}

extension BriefBuilder {
    /// GTD's weekly review, prepared from data on this Mac: get clear (the inbox), get current (projects without a next
    /// action, follow-ups, projects due for review, what comes back from the tickler), get creative (someday, goals).
    /// Rows that are not one task carry `.task("")`, which opens the Tasks section.
    package static func review(_ input: BriefInput) -> Brief {
        let now = input.now
        let week = DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
        let nextWeek = now.addingTimeInterval(7 * 86_400)
        var sections: [Brief.Section] = []
        var lines: [String] = []

        if !input.suggestions.isEmpty {
            sections.append(.init(id: "inbox", title: "Get clear: inbox", items: input.suggestions.prefix(10).map {
                Brief.Item(id: "inbox:\($0.id)", symbol: "tray", title: $0.headline, subtitle: $0.clarify.map { "Files as: \($0.summary)" },
                           target: .task(""))
            }))
            lines.append("Inbox: \(input.suggestions.count) to clarify")
        }

        let open: Set<TaskStatus> = [.backlog, .inProgress, .needsYou]
        let stalled = input.projects.filter { project in
            project.status == .active && !input.tasks.contains { task in
                task.project == project.id && open.contains(task.status) && task.waitingOn == nil && !task.isDeferred(now: now)
            }
        }
        if !stalled.isEmpty {
            sections.append(.init(id: "stalled", title: "Get current: projects without a next action", items: stalled.map {
                Brief.Item(id: "stalled:\($0.id)", symbol: "exclamationmark.triangle", title: $0.title,
                           subtitle: $0.outcome.isEmpty ? nil : $0.outcome, target: .task(""))
            }))
            lines.append("\(stalled.count) \(stalled.count == 1 ? "project needs" : "projects need") a next action")
        }

        let followUps = input.tasks.filter { $0.followUpDue(now: now, calendar: input.calendar) }
        if !followUps.isEmpty {
            sections.append(.init(id: "follow-ups", title: "Get current: follow up", items: followUps.map {
                Brief.Item(id: "follow:\($0.id)", symbol: "arrowshape.turn.up.right", title: $0.title, subtitle: $0.waitingLabel, target: .task($0.id))
            }))
            lines.append("\(followUps.count) \(followUps.count == 1 ? "follow-up" : "follow-ups") due")
        }

        let dueForReview = input.projects.filter { $0.isDueForReview(now: now) && !stalled.contains($0) }
        if !dueForReview.isEmpty {
            sections.append(.init(id: "projects", title: "Get current: projects to review", items: dueForReview.map {
                Brief.Item(id: "review:\($0.id)", symbol: "folder", title: $0.title, subtitle: "Due for review", target: .task(""))
            }))
        }

        let returning = input.tasks.filter { task in task.isDeferred(now: now) && (task.deferUntil.map { $0 <= nextWeek } ?? false) }
            .sorted { ($0.deferUntil ?? now) < ($1.deferUntil ?? now) }
        if !returning.isEmpty {
            sections.append(.init(id: "returning", title: "Get current: back next week", items: returning.map {
                Brief.Item(id: "back:\($0.id)", symbol: "moon.zzz", title: $0.title,
                           subtitle: $0.deferUntil.map { "Back \($0.formatted(date: .abbreviated, time: .omitted))" }, target: .task($0.id))
            }))
        }

        let someday = input.tasks.filter { $0.status == .someday }
        if !someday.isEmpty {
            sections.append(.init(id: "someday", title: "Get creative: someday", items: someday.prefix(10).map {
                Brief.Item(id: "someday:\($0.id)", symbol: "sparkles", title: $0.title, target: .task($0.id))
            }))
        }

        let goals = input.goals.filter { $0.status == .active }
        if !goals.isEmpty {
            sections.append(.init(id: "goals", title: "Get creative: goals", items: goals.map { goal in
                let results = input.keyResults.filter { $0.goal == goal.id }
                let progress = results.isEmpty ? nil : results.map(\.progress).reduce(0, +) / Double(results.count)
                return Brief.Item(id: "goal:\(goal.id)", symbol: "target", title: goal.title,
                                  subtitle: progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "No key results yet", target: .task(""))
            }))
        }

        let score = GoalAlignment.score(input, in: week)
        if let alignment = GoalAlignment.section(score) { sections.append(alignment) }
        if let score { lines.append(score.title) }
        return Brief(kind: .review, window: week, sections: sections, lines: Array(lines.prefix(4)))
    }
}
