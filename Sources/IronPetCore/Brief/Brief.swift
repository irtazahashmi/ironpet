import Foundation
import enum IronPetKit.SharedSymbols

/// The morning brief or the end-of-day recap: sections of items, each of which opens something. Built by `BriefBuilder`
/// from data on this Mac only.
package struct Brief: Equatable, Codable {
    package init(kind: Kind, window: DateInterval, sections: [Section], lines: [String]) {
        self.kind = kind
        self.window = window
        self.sections = sections
        self.lines = lines
    }

    package enum Kind: String, CaseIterable, Identifiable, Codable {
        case brief, recap
        package var id: String { rawValue }
        package var title: String { self == .brief ? "Morning brief" : "Today's recap" }
        package var pickerTitle: String { self == .brief ? "Brief" : "Recap" }
        package var symbol: String { self == .brief ? "sun.max.fill" : "moon.stars.fill" }
        package var emptyText: String { self == .brief ? "Nothing needs you this morning." : "Quiet day: nothing finished or closed today." }
    }

    /// What a row opens.
    package enum Target: Equatable, Codable {
        case task(String)
        /// A watched agent session. `workspace`, `bundleID` and `iterm` reopen it once the session has ended.
        case session(id: String, workspace: String?, bundleID: String?, iterm: String? = nil)
        case alert(id: String, url: URL?)
        /// A meeting folder name under `~/.ironpet/meetings`.
        case meeting(String)
    }

    package struct Item: Identifiable, Equatable, Codable {
        package init(id: String, symbol: String, title: String, subtitle: String? = nil, target: Target) {
            self.id = id
            self.symbol = symbol
            self.title = title
            self.subtitle = subtitle
            self.target = target
        }

        package let id: String
        package var symbol: String
        package var title: String
        package var subtitle: String?
        package var target: Target
    }

    package struct Section: Identifiable, Equatable, Codable {
        package init(id: String, title: String, items: [Item]) {
            self.id = id
            self.title = title
            self.items = items
        }

        package let id: String
        package var title: String
        package var items: [Item]
    }

    package var kind: Kind
    package var window: DateInterval
    package var sections: [Section]
    /// The bubble's text: at most four short lines, most important first.
    package var lines: [String]

    package var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }
}

/// Something that happened, for the recap: an agent turn that ended, an alert its watcher resolved. It comes from the shared
/// activity log through `BriefActivitySource`.
package struct BriefActivity: Equatable {
    package init(
        kind: Kind,
        at: Date,
        ref: String,
        title: String,
        detail: String? = nil,
        agent: String? = nil,
        workspace: String? = nil,
        bundleID: String? = nil,
        iterm: String? = nil
    ) {
        self.kind = kind
        self.at = at
        self.ref = ref
        self.title = title
        self.detail = detail
        self.agent = agent
        self.workspace = workspace
        self.bundleID = bundleID
        self.iterm = iterm
    }

    package enum Kind: Equatable { case sessionDone, sessionFailed, alertResolved }
    package var kind: Kind
    package var at: Date
    /// The session key or the alert's signal id.
    package var ref: String
    /// The workspace name for a session, the alert's title for an alert.
    package var title: String
    /// The session's one-line summary, the alert's label.
    package var detail: String?
    package var agent: String?
    package var workspace: String?
    package var bundleID: String?
    package var iterm: String? = nil
}

/// Where the recap reads what happened. The activity log implements it; tests and previews pass a list.
package protocol BriefActivitySource {
    func briefActivity(in window: DateInterval) -> [BriefActivity]
}

package struct FixedBriefActivity: BriefActivitySource {
    package init(events: [BriefActivity]) {
        self.events = events
    }

    package var events: [BriefActivity]
    package func briefActivity(in window: DateInterval) -> [BriefActivity] { events.filter { window.contains($0.at) } }
}

/// A meeting folder with the unticked action items of its summary that are the user's.
package struct BriefMeeting: Equatable {
    package init(id: String, date: Date, preview: String, openItems: [String]) {
        self.id = id
        self.date = date
        self.preview = preview
        self.openItems = openItems
    }

    package var id: String
    package var date: Date
    package var preview: String
    package var openItems: [String]
}

/// Everything the builder reads, gathered once so the rules can be tested with a fixed clock.
package struct BriefInput {
    package init(
        now: Date,
        calendar: Calendar = .current,
        day: Date? = nil,
        tasks: [TaskItem] = [],
        sessions: [AgentSession] = [],
        alerts: [Signal] = [],
        meetings: [BriefMeeting] = [],
        activity: [BriefActivity] = []
    ) {
        self.now = now
        self.calendar = calendar
        self.day = day
        self.tasks = tasks
        self.sessions = sessions
        self.alerts = alerts
        self.meetings = meetings
        self.activity = activity
    }

    package var now: Date
    package var calendar: Calendar = .current
    /// The day the recap covers, from its start to `now`. Nil is the day of `now`.
    package var day: Date? = nil
    package var tasks: [TaskItem] = []
    package var sessions: [AgentSession] = []
    package var alerts: [Signal] = []
    package var meetings: [BriefMeeting] = []
    package var activity: [BriefActivity] = []
}

package enum BriefBuilder {
    /// The brief's meetings start on the previous day the trigger runs, so Monday's brief with weekdays mon–fri covers
    /// Friday to Sunday. Without weekdays, yesterday.
    package static func meetingsSince(weekdays: [String]?, now: Date, calendar: Calendar) -> Date {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let allowed = Set(weekdays ?? names)
        let today = calendar.startOfDay(for: now)
        for offset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { break }
            if allowed.contains(names[calendar.component(.weekday, from: day) - 1]) { return day }
        }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    package static func build(_ kind: Brief.Kind, _ input: BriefInput, meetingsSince: Date? = nil) -> Brief {
        kind == .brief ? brief(input, meetingsSince: meetingsSince) : recap(input)
    }

    // MARK: Brief

    package static func brief(_ input: BriefInput, meetingsSince: Date? = nil) -> Brief {
        let now = input.now, calendar = input.calendar
        let since = meetingsSince ?? self.meetingsSince(weekdays: nil, now: now, calendar: calendar)
        let open = input.tasks.filter { $0.status != .done }
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now

        let due = open.filter { task in task.due.map { $0 < endOfToday } ?? false }.sorted { ($0.due!, $0.id) < ($1.due!, $1.id) }
        let overdue = due.filter { $0.isOverdue(now: now, calendar: calendar) }
        let dueItems = due.map { task in
            Brief.Item(id: "due:\(task.id)", symbol: task.isOverdue(now: now, calendar: calendar) ? "calendar.badge.exclamationmark" : "calendar",
                       title: task.title, subtitle: task.dueLabel(now: now, calendar: calendar), target: .task(task.id))
        }
        let dueIDs = Set(due.map(\.id))
        let needsYou = open.filter { $0.needsUser && !dueIDs.contains($0.id) }.sorted { $0.updated > $1.updated }
        let needsItems = needsYou.map { Brief.Item(id: "needs:\($0.id)", symbol: "person.fill.questionmark", title: $0.title,
                                                   subtitle: "Needs you", target: .task($0.id)) }

        let alerts = orderedAlerts(actionable(input.alerts))
        let alertItems = alerts.map(alertItem)

        let done = input.tasks.filter { $0.status == .done }.map { ActionItems.normalized($0.title) }
        let openTasks = Dictionary(open.map { (ActionItems.normalized($0.title), $0.id) }, uniquingKeysWith: { first, _ in first })
        var meetingItems: [Brief.Item] = []
        for meeting in input.meetings.filter({ $0.date >= since && $0.date <= now }).sorted(by: { $0.date < $1.date }) {
            for (index, text) in meeting.openItems.enumerated() where !done.contains(ActionItems.normalized(text)) {
                let target: Brief.Target = openTasks[ActionItems.normalized(text)].map { .task($0) } ?? .meeting(meeting.id)
                meetingItems.append(.init(id: "meeting:\(meeting.id):\(index)", symbol: SharedSymbols.meetings, title: text,
                                          subtitle: meetingLabel(meeting, now: now, calendar: calendar), target: target))
            }
        }

        let waiting = waitingSessions(input.sessions)
        let waitingItems = waiting.map(sessionItem)

        let sections = [
            Brief.Section(id: "due", title: "Due", items: dueItems),
            Brief.Section(id: "needs", title: "Needs you", items: needsItems),
            Brief.Section(id: "alerts", title: "Alerts", items: alertItems),
            Brief.Section(id: "meetings", title: "From recent meetings", items: meetingItems),
            Brief.Section(id: "agents", title: "Agents waiting", items: waitingItems),
        ]
        var lines: [String] = []
        if !due.isEmpty {
            let today = due.count - overdue.count
            switch (today, overdue.count) {
            case (0, let late): lines.append("\(count(late, "task")) overdue")
            case (let t, 0): lines.append("\(count(t, "task")) due today")
            case (let t, let late): lines.append("\(count(t, "task")) due today, \(late) overdue")
            }
        }
        if !needsYou.isEmpty { lines.append("\(count(needsYou.count, "task")) \(needsYou.count == 1 ? "needs" : "need") you") }
        if !alerts.isEmpty { lines.append(alertLine(alerts)) }
        if !meetingItems.isEmpty { lines.append("\(count(meetingItems.count, "open action item")) from meetings") }
        if !waiting.isEmpty { lines.append("\(count(waiting.count, "agent")) waiting for you") }
        return Brief(kind: .brief, window: DateInterval(start: min(since, now), end: now), sections: sections, lines: Array(lines.prefix(4)))
    }

    // MARK: Recap

    package static func recap(_ input: BriefInput) -> Brief {
        let now = input.now, calendar = input.calendar
        let window = DateInterval(start: min(calendar.startOfDay(for: input.day ?? now), now), end: now)
        let today = input.activity.filter { window.contains($0.at) }.sorted { $0.at > $1.at }

        let turns = today.filter { $0.kind == .sessionDone || $0.kind == .sessionFailed }
        let failed = turns.filter { $0.kind == .sessionFailed }.count
        let turnItems = turns.enumerated().map { index, event in
            Brief.Item(id: "turn:\(event.ref):\(index)", symbol: event.kind == .sessionFailed ? "xmark.octagon.fill" : SharedSymbols.done,
                       title: event.title, subtitle: [event.kind == .sessionFailed ? "Failed" : nil, event.agent, event.detail]
                        .compactMap { $0 }.joined(separator: " · "),
                       target: .session(id: event.ref, workspace: event.workspace, bundleID: event.bundleID, iterm: event.iterm))
        }

        let closed = input.tasks.filter { task in task.status == .done && task.closed.map(window.contains) == true }.sorted { $0.closed! > $1.closed! }
        let closedItems = closed.map { Brief.Item(id: "closed:\($0.id)", symbol: "checkmark.circle", title: $0.title, subtitle: "Done", target: .task($0.id)) }

        let resolved = today.filter { $0.kind == .alertResolved }
        let resolvedItems = resolved.enumerated().map { index, event in
            Brief.Item(id: "resolved:\(event.ref):\(index)", symbol: "checkmark.seal.fill", title: event.title,
                       subtitle: event.detail.map { "\($0) · resolved" } ?? "Resolved", target: .alert(id: event.ref, url: nil))
        }

        let meetings = input.meetings.filter { window.contains($0.date) }.sorted { $0.date < $1.date }
        let meetingItems = meetings.map { m in
            Brief.Item(id: "held:\(m.id)", symbol: SharedSymbols.meetings, title: m.preview.isEmpty ? "Meeting" : m.preview,
                       subtitle: meetingLabel(m, now: now, calendar: calendar), target: .meeting(m.id))
        }

        let stillTasks = input.tasks.filter { $0.waitingOn == nil && ($0.status == .needsYou || $0.status == .inProgress) }
            .sorted { ($0.status == .needsYou ? 0 : 1, $0.updated) < ($1.status == .needsYou ? 0 : 1, $1.updated) }
        let stillAlerts = orderedAlerts(actionable(input.alerts))
        let stillAgents = waitingSessions(input.sessions)
        let stillItems = stillTasks.map { Brief.Item(id: "open:\($0.id)", symbol: $0.status == .needsYou ? "person.fill.questionmark" : "arrow.triangle.2.circlepath",
                                                     title: $0.title, subtitle: $0.status.title, target: .task($0.id)) }
            + stillAlerts.map(alertItem) + stillAgents.map(sessionItem)

        let sections = [
            Brief.Section(id: "agents", title: "Agents", items: turnItems),
            Brief.Section(id: "closed", title: "Tasks closed", items: closedItems),
            Brief.Section(id: "resolved", title: "Alerts resolved", items: resolvedItems),
            Brief.Section(id: "meetings", title: "Meetings", items: meetingItems),
            Brief.Section(id: "open", title: "Still open", items: stillItems),
        ]
        var lines: [String] = []
        if !turns.isEmpty {
            let finished = turns.count - failed
            switch (finished, failed) {
            case (0, let f): lines.append("\(count(f, "agent turn")) failed")
            case (let d, 0): lines.append("Agents finished \(count(d, "turn"))")
            case (let d, let f): lines.append("Agents finished \(count(d, "turn")), \(f) failed")
            }
        }
        if !closed.isEmpty { lines.append("\(count(closed.count, "task")) closed") }
        if !resolved.isEmpty { lines.append("\(count(resolved.count, "alert")) resolved") }
        if !meetings.isEmpty { lines.append(count(meetings.count, "meeting")) }
        var open: [String] = []
        if !stillTasks.isEmpty { open.append(count(stillTasks.count, "task")) }
        if !stillAlerts.isEmpty { open.append(count(stillAlerts.count, "alert")) }
        if !stillAgents.isEmpty { open.append(count(stillAgents.count, "agent")) }
        // "Still open" always makes it into the bubble.
        lines = Array(lines.prefix(open.isEmpty ? 4 : 3))
        if !open.isEmpty { lines.append("Still open: " + open.joined(separator: ", ")) }
        return Brief(kind: .recap, window: window, sections: sections, lines: lines)
    }

    // MARK: Parts

    /// "1 task", "3 tasks".
    package static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private static let labelOrder = ["Review requested", "CI failed", "Changes requested"]

    /// Review requests, failing CI and changes requested first, then the rest by label, newest first within a label.
    package static func orderedAlerts(_ alerts: [Signal]) -> [Signal] {
        func rank(_ s: Signal) -> Int { labelOrder.firstIndex(of: s.label) ?? labelOrder.count }
        return alerts.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.label != b.label { return a.label < b.label }
            return a.date > b.date
        }
    }

    /// Alerts that ask for something. Good news such as an approved PR is left out.
    package static func actionable(_ alerts: [Signal]) -> [Signal] { alerts.filter { $0.mood != .done } }

    /// "2 review requested, 1 CI failed", "+3 more" past two labels, so the line fits the bubble.
    package static func alertLine(_ alerts: [Signal]) -> String {
        var groups: [(label: String, count: Int)] = []
        for alert in orderedAlerts(alerts) {
            if let i = groups.firstIndex(where: { $0.label == alert.label }) { groups[i].count += 1 } else { groups.append((alert.label, 1)) }
        }
        let named = groups.prefix(2).map { "\($0.count) \(lowerFirst($0.label))" }.joined(separator: ", ")
        let rest = groups.dropFirst(2).reduce(0) { $0 + $1.count }
        return rest > 0 ? "\(named) +\(rest) more" : named
    }

    /// "Review requested" becomes "review requested"; "CI failed" stays.
    package static func lowerFirst(_ text: String) -> String {
        let chars = Array(text)
        guard chars.count > 1, chars[0].isUppercase, chars[1].isLowercase else { return text }
        return chars[0].lowercased() + String(chars.dropFirst())
    }

    private static func alertItem(_ s: Signal) -> Brief.Item {
        Brief.Item(id: "alert:\(s.id)", symbol: s.symbol, title: s.title,
                   subtitle: [s.label, s.subtitle].filter { !$0.isEmpty }.joined(separator: " · "), target: .alert(id: s.id, url: s.url))
    }

    /// Sessions that wait on the user, and failed ones nobody has looked at yet.
    package static func waitingSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { $0.status == .needsInput || $0.status == .failed }
            .sorted { ($0.status, $0.updatedAt) > ($1.status, $1.updatedAt) }
    }

    private static func sessionItem(_ s: AgentSession) -> Brief.Item {
        let state = s.status == .needsInput ? "\(s.source.displayName) needs input" : "\(s.source.displayName) failed"
        return Brief.Item(id: "session:\(s.id)", symbol: s.status == .needsInput ? SharedSymbols.approval : "xmark.octagon.fill",
                          title: s.workspaceName, subtitle: [state, s.summary].compactMap { $0 }.joined(separator: " · "),
                          target: .session(id: s.id, workspace: s.origin.workspace, bundleID: s.origin.ownerBundleID,
                                           iterm: s.isInIterm ? s.origin.itermSessionID : nil))
    }

    /// "Meeting Fri 14:00", or "Meeting today 14:00".
    package static func meetingLabel(_ m: BriefMeeting, now: Date, calendar: Calendar) -> String {
        var time = Date.FormatStyle.dateTime.hour().minute()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        var day = Date.FormatStyle.dateTime.weekday(.abbreviated)
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        let name: String
        if calendar.isDate(m.date, inSameDayAs: now) { name = "today" }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(m.date, inSameDayAs: yesterday) { name = "yesterday" }
        else { name = m.date.formatted(day) }
        return "Meeting \(name) \(m.date.formatted(time))"
    }
}
