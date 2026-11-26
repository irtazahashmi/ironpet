import Foundation
import enum IronPetKit.SharedSymbols

/// Where an inbox item came from. Shown as a symbol in the list.
package enum TaskSource: String, CaseIterable, Codable {
    case chat, telegram, meeting, automation, cli, agent, user, capture, email, pr

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
        }
    }

    /// The kinds an agent may name in an item's `origin`. Telegram and the CLI are ways in, not origins.
    package static let originKinds: [TaskSource] = [.chat, .agent, .meeting, .capture, .automation, .email, .pr, .user]
}

/// Something an inbox item points at: the meeting it came from or a web page.
package struct TaskLink: Equatable, Codable {
    package init(kind: Kind, ref: String, label: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.label = label
    }

    /// `meeting` names a meeting folder, which the Mac opens in its transcripts. `url` is a web page.
    package enum Kind: String, CaseIterable, Codable { case url, meeting }
    package var kind: Kind
    package var ref: String
    package var label: String?
}

/// An inbox item: an action item from a meeting summary, or something a watcher automation or an agent found, that waits until the
/// user marks it done or removes it. It is text only and never sent to an agent.
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
        sourceRef: String? = nil
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.notes = notes
        self.url = url
        self.origin = origin
        self.created = created
        self.waitingOn = waitingOn
        self.sourceRef = sourceRef
    }

    package enum Origin: Equatable, Codable {
        /// The meeting folder.
        case meeting(URL)
        case automation(id: String, name: String)
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
        /// Where the draft came from, when the producer knows. Used when `store` is not given a reference.
        package var sourceRef: String?
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
    /// Where the suggestion came from, for diagnostics: a JSON object.
    package var sourceRef: String? = nil

    package var meeting: URL? {
        if case .meeting(let url) = origin { return url }
        return nil
    }

    /// Where the item came from, as links the user can open: the meeting it was written in, and the page the watcher or agent named.
    package var links: [TaskLink] {
        var links: [TaskLink] = []
        if let folder = meeting { links.append(TaskLink(kind: .meeting, ref: folder.lastPathComponent, label: "Meeting")) }
        if let url { links.append(TaskLink(kind: .url, ref: url.absoluteString)) }
        return links
    }

    /// What kind of source the item came from.
    package var source: TaskSource {
        switch origin {
        case .meeting: return .meeting
        case .automation: return .automation
        }
    }

    /// "Meeting", or "From" and the automation's name.
    package var originLabel: String {
        switch origin {
        case .meeting: return "Meeting"
        case .automation(_, let name): return "From \(name)"
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

/// An item's source reference: a JSON object kept as text, keys sorted.
package enum TaskRef {
    package static func text(_ object: [String: Any]) -> String? {
        guard !object.isEmpty, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Checks agent input before it reaches the database.
package enum TaskValidator {
    package static let maxTitle = 200
    package static let maxNotes = 4096
    package static let maxWaitingOn = 100

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
}

/// Relative times for inbox rows. A time up to a minute ahead of the clock, or less than a second behind it, reads "just now"
/// instead of "in 0 sec.", because an item is stamped by one clock read and drawn by a later one.
package enum TaskTime {
    package static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = date.timeIntervalSince(now)
        if delta > -1, delta < 60 { return "just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}
