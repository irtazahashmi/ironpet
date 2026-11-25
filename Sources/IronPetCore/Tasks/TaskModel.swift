import Foundation
import enum IronPetKit.SharedSymbols
import struct IronPetKit.RemoteSuggestionUpdate
import struct IronPetKit.RemoteSuggestionClarify

/// Where a task stands. The agent moves tasks between these; the user only marks them done.
package enum TaskStatus: String, CaseIterable, Codable {
    case backlog
    case inProgress = "in_progress"
    case needsYou = "needs_you"
    /// Not committed to: maybe later. Never a next action; looked at in the weekly review.
    case someday
    case done

    package var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .inProgress: return "In progress"
        case .needsYou: return "Needs you"
        case .someday: return "Someday"
        case .done: return "Done"
        }
    }
}

/// What created a task. Shown as a symbol in the list.
package enum TaskSource: String, CaseIterable, Codable {
    case chat, telegram, meeting, automation, cli, agent, user, capture, email, pr, scan

    package var symbol: String {
        switch self {
        case .chat: return "bubble.left"
        case .telegram: return "paperplane"
        case .meeting: return SharedSymbols.meetings
        case .automation: return SharedSymbols.automations
        case .cli: return "terminal"
        case .agent: return "sparkles"
        case .user: return "person"
        case .capture: return "text.viewfinder"
        case .email: return "envelope"
        case .pr: return "arrow.triangle.pull"
        case .scan: return "text.magnifyingglass"
        }
    }

    /// The kinds an agent may name in a task's `origin`. Telegram and the CLI are ways in, not origins.
    package static let originKinds: [TaskSource] = [.chat, .agent, .meeting, .capture, .automation, .email, .pr, .user]
}

/// Something a task points at: a chat thread, a watched agent session, a URL or a file.
package struct TaskLink: Equatable, Codable {
    package init(kind: Kind, ref: String, label: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.label = label
    }

    package enum Kind: String, CaseIterable, Codable { case thread, session, url, file }
    package var kind: Kind
    package var ref: String
    package var label: String?
}

package struct TaskItem: Identifiable, Equatable, Codable {
    package init(
        id: String,
        title: String,
        notes: String,
        status: TaskStatus,
        source: TaskSource,
        due: Date? = nil,
        links: [TaskLink],
        created: Date,
        updated: Date,
        closed: Date? = nil,
        waitingOn: String? = nil,
        sourceRef: String? = nil,
        labels: [String: String] = [:],
        deferUntil: Date? = nil,
        project: String? = nil
    ) {
        self.project = project
        self.deferUntil = deferUntil
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.source = source
        self.due = due
        self.links = links
        self.created = created
        self.updated = updated
        self.closed = closed
        self.waitingOn = waitingOn
        self.sourceRef = sourceRef
        self.labels = labels
    }

    package let id: String
    package var title: String
    package var notes: String
    package var status: TaskStatus
    package var source: TaskSource
    package var due: Date?
    package var links: [TaskLink]
    package var created: Date
    package var updated: Date
    package var closed: Date?
    /// Who the user is waiting on (`Ana`, `Them`). Nil for the user's own work.
    package var waitingOn: String? = nil
    /// Where the task came from, for diagnostics: a JSON object such as `{"meeting": "/path"}`. Nil when unknown.
    package var sourceRef: String? = nil
    /// Key/value labels such as `merge=auto`. Data for filtering, never instructions.
    package var labels: [String: String] = [:]
    /// The public `task_<hex>` id (see `RecordID`). `TaskStore` fills it in when it reads the task; nil for a value that did not come from the store.
    package var ref: String? = nil

    /// The tickler: the task stays out of the list until this moment (a plain date is local midnight). Nil shows it now.
    package var deferUntil: Date? = nil
    /// The id of the GTD project this task is a step of (`TaskProject`). Nil for a standalone task.
    package var project: String? = nil

    /// Hidden until its defer date. A done task is never deferred.
    package func isDeferred(now: Date = Date()) -> Bool {
        guard status != .done, let deferUntil else { return false }
        return deferUntil > now
    }

    /// Only the user can take the next step. A task waiting on someone else, or deferred to a later day, never counts.
    package var needsUser: Bool { needsUser(now: Date()) }

    package func needsUser(now: Date) -> Bool { status == .needsYou && waitingOn == nil && !isDeferred(now: now) }
}

/// One line of a task's history: created, a status change, a note, closed. Nothing is overwritten, so a task the agent
/// rewrote can still be traced.
package struct TaskEvent: Equatable, Codable {
    package init(at: Date, by: String, kind: Kind, detail: String) {
        self.at = at
        self.by = by
        self.kind = kind
        self.detail = detail
    }

    package enum Kind: String, Codable { case created, status, edited, note, closed, deleted }
    package var at: Date
    /// `user`, `agent:mcp`, `agent:cli`, `meeting`.
    package var by: String
    package var kind: Kind
    package var detail: String
}

/// An action item from a meeting summary, or a task a watcher automation proposed, that waits for Add or Skip.
/// It is text only and never sent to an agent.
package struct TaskSuggestion: Identifiable, Equatable, Codable {
    package init(
        id: String,
        title: String,
        due: String? = nil,
        notes: String = "",
        url: URL? = nil,
        origin: Origin,
        created: Date,
        waitingOn: String? = nil,
        sourceRef: String? = nil,
        update: Update? = nil,
        clarify: Clarify? = nil
    ) {
        self.clarify = clarify
        self.id = id
        self.title = title
        self.due = due
        self.notes = notes
        self.url = url
        self.origin = origin
        self.created = created
        self.waitingOn = waitingOn
        self.sourceRef = sourceRef
        self.update = update
    }

    package enum Origin: Equatable, Codable {
        /// The meeting folder.
        case meeting(URL)
        case automation(id: String, name: String)
        /// The scheduled task scan of chats, meetings and the screen.
        case taskScan
    }

    /// A change to a task that already exists. Accepting the suggestion applies it, skipping leaves the task as it is.
    package struct Update: Equatable, Codable {
        package init(target: String, targetTitle: String, note: String? = nil, markDone: Bool = false, waitingOn: String? = nil) {
            self.target = target
            self.targetTitle = targetTitle
            self.note = note
            self.markDone = markDone
            self.waitingOn = waitingOn
        }

        /// The id of the task to change.
        package var target: String
        /// The task's title when the suggestion was filed. The inbox shows it, and it is not looked up again.
        package var targetTitle: String
        /// Text appended to the task's notes.
        package var note: String?
        /// Sets the status to done.
        package var markDone = false
        /// Who the task now waits on.
        package var waitingOn: String?

        package var isEmpty: Bool { !markDone && (note ?? "").isEmpty && (waitingOn ?? "").isEmpty }

        /// The Kit form, which holds the wording shown on the Mac and on the iPhone.
        package var remote: RemoteSuggestionUpdate {
            RemoteSuggestionUpdate(taskID: target, taskTitle: targetTitle, note: note, status: markDone ? "done" : nil, waitingOn: waitingOn)
        }

        /// `Mark done. Waiting on Tom. Note: sent the deck.`
        package var summary: String { remote.summary }
    }

    /// How the agent proposes to file a new task (GTD's clarify step). Adding the suggestion applies it in one tap.
    package struct Clarify: Equatable, Codable {
        package init(context: TaskContext? = nil, area: String? = nil, twoMinute: Bool = false, someday: Bool = false) {
            self.context = context
            self.area = area
            self.twoMinute = twoMinute
            self.someday = someday
        }

        /// Where it can be done; becomes the `context` label.
        package var context: TaskContext?
        /// What it belongs to; becomes the `area` label.
        package var area: String?
        /// Takes under two minutes, so it is better done now than tracked.
        package var twoMinute = false
        /// Not a commitment yet: the task is filed as someday.
        package var someday = false

        package var isEmpty: Bool { context == nil && area == nil && !twoMinute && !someday }

        /// The labels the task gets.
        package var labels: [String: String] {
            var labels: [String: String] = [:]
            if let context { labels[TaskContext.key] = context.rawValue }
            if let area { labels["area"] = area }
            return labels
        }

        /// `Phone · Health · 2 min · Someday`
        package var summary: String {
            RemoteSuggestionClarify(context: context?.rawValue, area: area, twoMinute: twoMinute, someday: someday).summary
        }
    }

    /// One suggestion before it is stored: a meeting action item, or what a watcher returned in a `suggest_task` action
    /// (cleaned by `init?(action:)`).
    package struct Draft: Equatable, Codable {
        package init(key: String, title: String, due: String? = nil, notes: String = "", url: URL? = nil, waitingOn: String? = nil,
                     sourceRef: String? = nil) {
            self.sourceRef = sourceRef
            self.key = key
            self.title = title
            self.due = due
            self.notes = notes
            self.url = url
            self.waitingOn = waitingOn
        }

        /// The action's `id`, unique within its automation.
        package var key: String
        package var title: String
        package var due: String?
        package var notes = ""
        package var url: URL?
        /// The owner of a meeting action item that is not the user. Watchers never set it.
        package var waitingOn: String?
        /// Where the draft came from, when the producer knows (the task scan). Used when `store` is not given a reference.
        package var sourceRef: String?
        /// The scan's proposal for filing it. Meetings and watchers leave it nil.
        package var clarify: Clarify?
    }

    package let id: String
    package var title: String
    /// Free text from a meeting ("Friday"); `yyyy-MM-dd` from an automation.
    package var due: String?
    package var notes = ""
    package var url: URL?
    package var origin: Origin
    package var created: Date
    /// The owner when it is not the user, so the task becomes one they wait on.
    package var waitingOn: String? = nil
    /// Where the suggestion came from, for diagnostics: a JSON object. Copied to the task on accept.
    package var sourceRef: String? = nil
    /// Set when the suggestion changes an existing task. The title then names that task.
    package var update: Update? = nil
    /// How to file it, when the task scan proposed one. Nil for meetings, watchers and updates.
    package var clarify: Clarify? = nil

    /// What the inbox shows as the headline: the title, or `Update: <task title>` for an update.
    package var headline: String { update?.remote.headline ?? title }

    package var meeting: URL? {
        if case .meeting(let url) = origin { return url }
        return nil
    }

    /// The source of the task it becomes.
    package var source: TaskSource {
        switch origin {
        case .meeting: return .meeting
        case .automation: return .automation
        case .taskScan: return .scan
        }
    }

    /// "Meeting", or "From" and the automation's name.
    package var originLabel: String {
        switch origin {
        case .meeting: return "Meeting"
        case .automation(_, let name): return "From \(name)"
        case .taskScan: return "Task scan"
        }
    }
}

extension TaskSuggestion.Draft {
    package static let maxKey = 200
    package static let maxTitle = 200
    package static let maxNotes = 2000
    package static let maxURL = 2048

    /// Reads a script's `{type: "suggest_task", id, title, due?, notes?, url?}`. The text comes from outside (mail, chat,
    /// issues), so it is clamped and stripped of control characters, and a due or url that does not parse is dropped.
    package init(action: [String: Any]) throws {
        func string(_ key: String) -> String? {
            guard let value = action[key], !(value is NSNull) else { return nil }
            return (value as? String) ?? "\(value)"
        }
        let key = Self.clean(string("id") ?? "", limit: Self.maxKey, newlines: false)
        guard !key.isEmpty else { throw TaskError(message: "a suggest_task needs an id") }
        let title = Self.clean(string("title") ?? "", limit: Self.maxTitle, newlines: false)
        guard !title.isEmpty else { throw TaskError(message: "a suggest_task needs a title") }
        self.key = key
        self.title = title
        if let raw = string("due")?.trimmingCharacters(in: .whitespaces), raw.count == 10, (try? TaskValidator.due(raw)) != nil {
            due = raw
        }
        notes = Self.clean(string("notes") ?? "", limit: Self.maxNotes, newlines: true)
        while notes.utf8.count > TaskValidator.maxNotes { notes.removeLast() }
        if let raw = string("url")?.trimmingCharacters(in: .whitespaces), raw.count <= Self.maxURL, let url = URL(string: raw),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false {
            self.url = url
        }
    }

    /// Drops control characters and bidirectional overrides, folds runs of whitespace in single-line text, trims and clamps.
    package static func clean(_ text: String, limit: Int, newlines: Bool) -> String {
        let bidi = Set<UInt32>([0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069))
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if bidi.contains(scalar.value) { continue }
            if newlines && scalar == "\n" { scalars.append(scalar); continue }
            if scalar == "\t" || scalar == "\n" || scalar == "\r" { scalars.append(" "); continue }
            if scalar.properties.generalCategory == .control { continue }
            scalars.append(scalar)
        }
        var result = String(scalars)
        if !newlines { result = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.count > limit ? String(result.prefix(limit)).trimmingCharacters(in: .whitespaces) : result
    }
}

extension TaskItem {
    /// "Waiting on Ana", "Waiting on them". Nil for the user's own work.
    package var waitingLabel: String? { waitingOn.map(describeWaiting) }
}

extension TaskSuggestion {
    package var waitingLabel: String? { waitingOn.map(describeWaiting) }
}

private func describeWaiting(_ owner: String) -> String {
    "Waiting on \(owner.caseInsensitiveCompare("them") == .orderedSame ? "them" : owner)"
}

package struct TaskError: Error, LocalizedError, Equatable {
    package init(message: String) {
        self.message = message
    }

    package let message: String
    package var errorDescription: String? { message }
}

/// Where a task can be done (GTD contexts). Kept as the `context` label, and only these values are accepted.
package enum TaskContext: String, CaseIterable, Codable {
    case mac, phone, calls, errands, agent, home

    package static let key = "context"

    package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The value in lower case, or an error that lists the allowed ones.
    package static func checked(_ raw: String) throws -> String {
        let value = raw.lowercased()
        guard TaskContext(rawValue: value) != nil else {
            throw TaskError(message: "context must be one of \(allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    }

    /// The context the labels name, or nil when there is none or it is not one of the six. Values stored before the
    /// check existed may have another case or spaces, so they are read the way the check would store them.
    package static func of(_ labels: [String: String]) -> TaskContext? {
        labels[key].flatMap { TaskContext(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }
}

/// Labels as one line, `a=1, b=2`, keys sorted.
package enum TaskLabels {
    package static func describe(_ labels: [String: String]) -> String {
        labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }
}

/// A task's source reference: a JSON object kept as text, keys sorted.
package enum TaskRef {
    package static func text(_ object: [String: Any]) -> String? {
        guard !object.isEmpty, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Checks agent and CLI input before it reaches the database.
package enum TaskValidator {
    package static let maxTitle = 200
    package static let maxNotes = 4096
    package static let maxLinks = 10
    package static let maxWaitingOn = 100
    package static let maxLabels = 20
    package static let maxLabelKey = 40
    package static let maxLabelValue = 100

    /// A label key: one word with no whitespace, control characters, `=` or `,`.
    package static func labelKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TaskError(message: "label key is empty") }
        guard key.count <= maxLabelKey else { throw TaskError(message: "label key \"\(key)\" is longer than \(maxLabelKey) characters") }
        guard !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .control || $0 == "=" || $0 == "," }) else {
            throw TaskError(message: "label key \"\(key)\" must not contain whitespace, \"=\" or \",\"")
        }
        return key
    }

    /// A `{key: value}` object. Values are strings (numbers and booleans are written as text) on one line.
    package static func labels(_ value: Any?) throws -> [String: String] {
        guard let value, !(value is NSNull) else { return [:] }
        guard let object = value as? [String: Any] else { throw TaskError(message: "labels must be an object of key/value strings") }
        var result: [String: String] = [:]
        for (rawKey, rawValue) in object {
            let key = try labelKey(rawKey)
            guard result[key] == nil else { throw TaskError(message: "label key \"\(key)\" is given twice") }
            let text: String
            if let string = rawValue as? String { text = string }
            else if let number = rawValue as? NSNumber { text = "\(number)" }
            else { throw TaskError(message: "label \"\(key)\" must have a string value") }
            var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw TaskError(message: "label \"\(key)\" has an empty value") }
            guard !clean.contains("\n"), clean.count <= maxLabelValue else {
                throw TaskError(message: "label \"\(key)\" must be one line of at most \(maxLabelValue) characters")
            }
            if key == TaskContext.key { clean = try TaskContext.checked(clean) }
            result[key] = clean
        }
        return result
    }

    /// A list of keys to remove.
    package static func labelKeys(_ value: Any?) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        let list = (value as? [Any]) ?? [value]
        return try list.map { item in
            guard let raw = item as? String else { throw TaskError(message: "remove_labels must be a list of keys") }
            return try labelKey(raw)
        }
    }

    package static func title(_ value: Any?) throws -> String {
        guard let raw = value as? String else { throw TaskError(message: "title must be a string") }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !title.isEmpty else { throw TaskError(message: "title is empty") }
        guard title.count <= maxTitle else { throw TaskError(message: "title is longer than \(maxTitle) characters") }
        return title
    }

    package static func notes(_ value: Any?) throws -> String {
        guard let value, !(value is NSNull) else { return "" }
        guard let notes = value as? String else { throw TaskError(message: "notes must be a string") }
        guard notes.utf8.count <= maxNotes else { throw TaskError(message: "notes are longer than \(maxNotes) bytes") }
        return notes
    }

    package static func status(_ value: Any?) throws -> TaskStatus {
        guard let raw = value as? String, let status = TaskStatus(rawValue: raw) else {
            throw TaskError(message: "status must be one of \(TaskStatus.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return status
    }

    package static func source(_ value: Any?, default fallback: TaskSource) throws -> TaskSource {
        guard let value, !(value is NSNull) else { return fallback }
        guard let raw = value as? String, let source = TaskSource(rawValue: raw) else {
            throw TaskError(message: "source must be one of \(TaskSource.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return source
    }

    /// A person's name on one line. Null or blank clears it.
    package static func waitingOn(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw TaskError(message: "waiting_on must be a string") }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard name.count <= maxWaitingOn else { throw TaskError(message: "waiting_on is longer than \(maxWaitingOn) characters") }
        return name.isEmpty ? nil : name
    }

    /// ISO 8601 with a time (`2026-11-20T15:30:00+01:00`) or a plain date (`2026-11-20`, local midnight). Null clears it.
    /// `field` names the argument in the error, `due` or `defer_until`.
    package static func due(_ value: Any?, field: String = "due") throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw TaskError(message: "\(field) must be an ISO 8601 date") }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: raw) { return date }
        throw TaskError(message: "\(field) \"\(raw)\" is not an ISO 8601 date such as 2026-11-20 or 2026-11-20T15:30:00+01:00")
    }

    package static func links(_ value: Any?) throws -> [TaskLink] {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [[String: Any]] else { throw TaskError(message: "links must be a list of {kind, ref, label?}") }
        guard list.count <= maxLinks else { throw TaskError(message: "at most \(maxLinks) links") }
        return try list.map { item in
            guard let raw = item["kind"] as? String, let kind = TaskLink.Kind(rawValue: raw) else {
                throw TaskError(message: "link kind must be one of \(TaskLink.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard let ref = (item["ref"] as? String)?.trimmingCharacters(in: .whitespaces), !ref.isEmpty, ref.count <= 2048 else {
                throw TaskError(message: "link ref must be a non-empty string")
            }
            if kind == .url, URL(string: ref)?.scheme.map({ ["http", "https"].contains($0.lowercased()) }) != true {
                throw TaskError(message: "url links must be http or https")
            }
            return TaskLink(kind: kind, ref: ref, label: (item["label"] as? String).map { String($0.prefix(100)) })
        }
    }
}

/// Relative times for task rows. A time up to a minute ahead of the clock, or less than a second behind it, reads "just now"
/// instead of "in 0 sec.", because a task is stamped by one clock read and drawn by a later one.
package enum TaskTime {
    package static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = date.timeIntervalSince(now)
        if delta > -1, delta < 60 { return "just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}
