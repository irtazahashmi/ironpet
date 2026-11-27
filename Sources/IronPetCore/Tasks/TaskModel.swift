import Foundation
import IronPetKit

/// Where an inbox item came from. Shown as a symbol in the list.
package enum TaskSource: String, CaseIterable, Codable {
    case chat, telegram, meeting, automation, cli, agent, user, capture, email, pr

    package var symbol: String { InboxKinds.symbol(rawValue) }

    /// The kinds an agent may name in an item's `origin`. Telegram and the CLI are ways in, not origins.
    package static let originKinds: [TaskSource] = [.chat, .agent, .meeting, .capture, .automation, .email, .pr, .user]
}

/// One note added to an inbox item, after it was created.
package struct InboxNote: Equatable {
    package init(at: Date, by: String, text: String) {
        self.at = at
        self.by = by
        self.text = text
    }

    package var at: Date
    /// Who added it: `cli`, `agent:mcp` or `user`.
    package var by: String
    package var text: String
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

/// One place an inbox item came from: the meeting it was written in, a mail, a PR, or a watcher. An item has one source when it is
/// created and gains another each time the same thing arrives from somewhere else, so the user sees every place it came from.
package struct InboxSource: Equatable, Codable {
    package init(kind: TaskSource, ref: String, url: URL? = nil, label: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.url = url
        self.label = label
    }

    package var kind: TaskSource
    /// A meeting folder path, an automation id, or whatever reference the agent named (a session, a thread, an id).
    package var ref: String
    /// The page for this source, http or https.
    package var url: URL?
    /// What the link button is called: "Meeting", "Email", the watcher's name.
    package var label: String?

    /// Two sources are the same place when they are the same kind and have the same url or the same non-empty reference. A mail and a
    /// pull request with one url are two sources, so the item says it came from both.
    package func isSame(as other: InboxSource) -> Bool {
        guard kind == other.kind else { return false }
        if let url, let other = other.url, InboxSource.normalized(url) == InboxSource.normalized(other) { return true }
        return !ref.isEmpty && ref == other.ref
    }

    /// A url compared without a trailing slash, the case of its scheme and host, or a fragment that is only a page anchor. A fragment that
    /// names something (it has a path or a digit, like Gmail `#inbox/<id>` or GitHub `#issuecomment-<n>`) stays, because it is the only
    /// part that tells two messages or comments apart.
    package static func normalized(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        if let fragment = parts.fragment, !fragment.contains("/"), !fragment.contains(where: \.isNumber) { parts.fragment = nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string ?? url.absoluteString
    }

    /// The word on the link button for a source an agent named.
    package static func displayName(_ kind: TaskSource) -> String { InboxKinds.title(kind.rawValue) }
}

/// What happened to one draft an agent or watcher filed.
package enum SuggestChange: Equatable {
    /// A new item.
    case added
    /// The id was seen before and its item is still in the inbox, so the item took the new text.
    case updated
    /// The draft named an existing item (`same_as`) or carried the same url as one, so that item gained a source.
    case merged
    /// Nothing was stored. The text says why.
    case ignored(String)

    /// Whether the draft ended up in an item.
    package var keepsItem: Bool {
        if case .ignored = self { return false }
        return true
    }
}

/// One draft's result, with the item it ended up in when there is one.
package struct SuggestFiling: Equatable {
    package init(change: SuggestChange, item: TaskSuggestion? = nil) {
        self.change = change
        self.item = item
    }

    package var change: SuggestChange
    package var item: TaskSuggestion?
}

/// An inbox item that left the list because its source resolved it, with the reason.
package struct ResolvedSuggestion: Identifiable, Equatable, Codable {
    package init(id: String, title: String, reason: String, resolved: Date, created: Date, due: String? = nil, sources: [InboxSource] = [],
                 resolvedBy: String? = nil) {
        self.resolvedBy = resolvedBy
        self.id = id
        self.title = title
        self.reason = reason
        self.resolved = resolved
        self.created = created
        self.due = due
        self.sources = sources
    }

    package let id: String
    package var title: String
    package var reason: String
    package var resolved: Date
    package var created: Date
    package var due: String?
    package var sources: [InboxSource]
    /// Who resolved the item: the inbox scan, an automation by its name, or an agent. Nil for an item resolved before this was stored.
    package var resolvedBy: String?

    /// `resolvedBy`, or "unknown" for an item resolved before the resolver was stored.
    package var resolverLabel: String { resolvedBy ?? "unknown" }
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
        sourceRef: String? = nil,
        sources: [InboxSource]? = nil
    ) {
        self.sources = sources ?? Self.firstSource(origin: origin, url: url)
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
                     sourceRef: String? = nil, sameAs: String? = nil) {
            self.sameAs = sameAs
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
        /// The id of an item already in the inbox that this is the same thing as, named by the caller. The item gains this draft's
        /// source instead of a second item appearing.
        package var sameAs: String?
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
    /// Every place the item came from, first the one that created it. A mail that arrives about a meeting's item adds a second.
    package var sources: [InboxSource]

    /// The source an item has when it is created: its origin and the page it names.
    package static func firstSource(origin: Origin, url: URL?) -> [InboxSource] {
        switch origin {
        case .meeting(let folder): return [InboxSource(kind: .meeting, ref: folder.path, url: url, label: "Meeting")]
        case .automation(let id, let name): return [InboxSource(kind: .automation, ref: id, url: url, label: name)]
        }
    }

    package var meeting: URL? {
        if case .meeting(let url) = origin { return url }
        return nil
    }

    /// Where the item came from, as links the user can open: one for the meeting it was written in and one for each page a source
    /// named. The same link is listed once.
    package var links: [TaskLink] {
        var links: [TaskLink] = []
        func add(_ link: TaskLink) { if !links.contains(link) { links.append(link) } }
        for source in sources {
            if source.kind == .meeting, source.ref.hasPrefix("/"), source.url == nil || source.ref == meeting?.path {
                add(TaskLink(kind: .meeting, ref: (source.ref as NSString).lastPathComponent, label: source.label ?? "Meeting"))
            }
            if let url = source.url {
                // A source's own name tells two links apart. The first watcher link stays unnamed, as it was before sources.
                let named = sources.count > 1 || source.kind != .automation
                add(TaskLink(kind: .url, ref: url.absoluteString, label: named ? source.label : nil))
            }
        }
        return links
    }

    /// What kind of source the item came from.
    package var source: TaskSource {
        switch origin {
        case .meeting: return .meeting
        case .automation: return .automation
        }
    }

    /// `originLabel`, and for a merged item the other sources by name: "Meeting and Email".
    package var fromLabel: String {
        guard sources.count > 1 else { return originLabel }
        var names: [String] = []
        for source in sources {
            let name = source.label ?? InboxSource.displayName(source.kind)
            if !names.contains(name) { names.append(name) }
        }
        return names.count > 1 ? "From " + names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : originLabel
    }

    /// The source a reader filters by. An item an agent or the CLI added keeps its kind (`email`, `pr`, `cli`), which the store
    /// records in the automation id as `agent:<kind>`.
    package var originKind: TaskSource {
        if case .automation(let id, _) = origin, id.hasPrefix("agent:"), let kind = TaskSource(rawValue: String(id.dropFirst("agent:".count))) {
            return kind
        }
        return source
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

    /// Reads a script's `{type: "suggest_task", id, title, due?, notes?, url?, same_as?}`. The text comes from outside (mail, chat,
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
        let named = Self.clean(string("same_as") ?? "", limit: Self.maxKey, newlines: false)
        sameAs = named.isEmpty ? nil : named
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
    /// What the error says when a resolve has no reason. A resolve is a claim that something was settled, so it needs the evidence.
    package static let reasonRequired = "reason is required: say what you checked that settled this item, for example \"PR 398 merged, checked with gh\""

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
