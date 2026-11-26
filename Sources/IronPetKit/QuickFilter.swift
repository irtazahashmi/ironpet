import Foundation

/// What a quick filter reads from a task. The Mac's `TaskItem` and the phone's `RemoteTask` both conform, so one evaluator serves both.
public protocol QuickFilterSubject {
    var filterTitle: String { get }
    var filterNotes: String { get }
    /// `backlog`, `in_progress`, `needs_you` or `done`.
    var filterStatus: String { get }
    var filterSource: String { get }
    var filterWaitingOn: String? { get }
    var filterDue: Date? { get }
    var filterLabels: [String: String] { get }
}

extension RemoteTask: QuickFilterSubject {
    public var filterTitle: String { title }
    public var filterNotes: String { notes }
    public var filterStatus: String { status.rawValue }
    public var filterSource: String { source }
    public var filterWaitingOn: String? { waitingOn }
    public var filterDue: Date? { due }
    public var filterLabels: [String: String] { labels }
}

/// Why a query was rejected. `path` names the node, such as `query.and[1].not`.
public struct QuickFilterError: Error, Equatable, Sendable {
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
    public var description: String { "\(path): \(message)" }
}

/// One node of a quick filter query: a boolean tree over a task's labels, status, due date, source and text.
///
/// The JSON form is an object with exactly one key:
/// `{"and": [...]}`, `{"or": [...]}`, `{"not": {...}}`, `{"label": {"key": "value"}}`, `{"labelExists": "key"}`,
/// `{"status": "done"}` or a list of statuses, `{"waitingOn": "Ana"}` or `null`, `{"due": {"before": "2026-12-01"}}`,
/// `{"due": {"after": "2026-12-01"}}`, `{"due": "overdue"}`, `{"due": "none"}`, `{"source": "meeting"}` or a list, and `{"text": "invoice"}`.
public indirect enum QuickFilterNode: Equatable, Sendable {
    case and([QuickFilterNode])
    case or([QuickFilterNode])
    case not(QuickFilterNode)
    case label(key: String, value: String)
    case labelExists(String)
    case status([String])
    /// A name, matched without regard to case, or nil for tasks that wait on nobody.
    case waitingOn(String?)
    case due(Due)
    case source([String])
    case text(String)

    public enum Due: Equatable, Sendable {
        /// Due on a day before this `YYYY-MM-DD` date. Tasks without a due date never match.
        case before(String)
        case after(String)
        /// Open and past due. A plain date is overdue once its day has passed.
        case overdue
        /// No due date.
        case none
    }

    public static let maxDepth = 8
    public static let maxNodes = 60
    // An older phone that cannot read a status skips only that filter (`QuickFilter.chips` drops a node it cannot parse).
    static let statuses = ["backlog", "in_progress", "needs_you", "someday", "done"]

    // MARK: Parsing

    /// Reads a query from decoded JSON. The error names the first bad node.
    public static func parse(_ value: Any) throws -> QuickFilterNode {
        var count = 0
        return try parse(value, path: "query", depth: 1, count: &count)
    }

    private static func fail(_ path: String, _ message: String) -> QuickFilterError { QuickFilterError(path: path, message: message) }

    private static func parse(_ value: Any, path: String, depth: Int, count: inout Int) throws -> QuickFilterNode {
        count += 1
        guard count <= maxNodes else { throw fail(path, "the query has more than \(maxNodes) conditions") }
        guard depth <= maxDepth else { throw fail(path, "conditions are nested deeper than \(maxDepth) levels") }
        guard let object = value as? [String: Any] else { throw fail(path, "must be an object with one key, such as {\"and\": [...]}") }
        guard object.count == 1, let key = object.keys.first, let operand = object[key] else {
            throw fail(path, object.isEmpty ? "is empty; use one of and, or, not, label, labelExists, status, waitingOn, due, source, text"
                                            : "has \(object.count) keys (\(object.keys.sorted().joined(separator: ", "))); each node has exactly one")
        }
        let here = "\(path).\(key)"
        switch key {
        case "and", "or":
            guard let list = operand as? [Any], !list.isEmpty else { throw fail(here, "must be a non-empty array of conditions") }
            var children: [QuickFilterNode] = []
            for (index, child) in list.enumerated() {
                children.append(try parse(child, path: "\(here)[\(index)]", depth: depth + 1, count: &count))
            }
            return key == "and" ? .and(children) : .or(children)
        case "not":
            return .not(try parse(operand, path: here, depth: depth + 1, count: &count))
        case "label":
            guard let pair = operand as? [String: Any], pair.count == 1, let name = pair.keys.first, let value = pair[name] as? String, !name.isEmpty else {
                throw fail(here, "must be an object with one key and a string value, such as {\"project\": \"epic\"}")
            }
            return .label(key: name, value: value)
        case "labelExists":
            guard let name = operand as? String, !name.isEmpty else { throw fail(here, "must be a label key (a non-empty string)") }
            return .labelExists(name)
        case "status":
            let names = try strings(operand, here, what: "a status")
            if let bad = names.first(where: { !statuses.contains($0) }) {
                throw fail(here, "\"\(bad)\" is not a status; use \(statuses.joined(separator: ", "))")
            }
            return .status(names)
        case "waitingOn":
            if operand is NSNull { return .waitingOn(nil) }
            guard let name = operand as? String, !name.isEmpty else { throw fail(here, "must be a name or null") }
            return .waitingOn(name)
        case "due":
            if let word = operand as? String {
                switch word {
                case "overdue": return .due(.overdue)
                case "none": return .due(.none)
                default: throw fail(here, "\"\(word)\" is not valid; use \"overdue\", \"none\", {\"before\": \"YYYY-MM-DD\"} or {\"after\": \"YYYY-MM-DD\"}")
                }
            }
            guard let bound = operand as? [String: Any], bound.count == 1, let side = bound.keys.first, side == "before" || side == "after" else {
                throw fail(here, "must be \"overdue\", \"none\", {\"before\": \"YYYY-MM-DD\"} or {\"after\": \"YYYY-MM-DD\"}")
            }
            guard let day = bound[side] as? String, isDay(day) else { throw fail("\(here).\(side)", "must be a date as YYYY-MM-DD") }
            return .due(side == "before" ? .before(day) : .after(day))
        case "source":
            return .source(try strings(operand, here, what: "a source"))
        case "text":
            guard let needle = operand as? String, !needle.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw fail(here, "must be a non-empty string")
            }
            return .text(needle)
        default:
            throw fail(path, "unknown condition \"\(key)\"; use and, or, not, label, labelExists, status, waitingOn, due, source, text")
        }
    }

    private static func strings(_ operand: Any, _ path: String, what: String) throws -> [String] {
        if let one = operand as? String, !one.isEmpty { return [one] }
        if let list = operand as? [Any], !list.isEmpty {
            var result: [String] = []
            for (index, item) in list.enumerated() {
                guard let text = item as? String, !text.isEmpty else { throw fail("\(path)[\(index)]", "must be \(what) (a non-empty string)") }
                result.append(text)
            }
            return result
        }
        throw fail(path, "must be \(what) or a non-empty array of them")
    }

    /// A real calendar day written `YYYY-MM-DD`.
    static func isDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    // MARK: Evaluating

    /// Whether the task matches. `now` and `calendar` decide what overdue and a due day mean, so tests set them.
    public func matches<T: QuickFilterSubject>(_ task: T, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .and(let children): return children.allSatisfy { $0.matches(task, now: now, calendar: calendar) }
        case .or(let children): return children.contains { $0.matches(task, now: now, calendar: calendar) }
        case .not(let child): return !child.matches(task, now: now, calendar: calendar)
        case .label(let key, let value): return task.filterLabels[key] == value
        case .labelExists(let key): return task.filterLabels[key] != nil
        case .status(let names): return names.contains(task.filterStatus)
        case .waitingOn(let name):
            guard let name else { return task.filterWaitingOn == nil }
            return task.filterWaitingOn?.caseInsensitiveCompare(name) == .orderedSame
        case .source(let names): return names.contains(task.filterSource)
        case .text(let needle):
            return task.filterTitle.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || task.filterNotes.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .due(let condition):
            switch condition {
            case .none: return task.filterDue == nil
            case .before(let day): return Self.day(task.filterDue, calendar).map { $0 < day } ?? false
            case .after(let day): return Self.day(task.filterDue, calendar).map { $0 > day } ?? false
            case .overdue:
                guard let due = task.filterDue, task.filterStatus != "done" else { return false }
                let allDay = calendar.dateComponents([.hour, .minute, .second], from: due) == DateComponents(hour: 0, minute: 0, second: 0)
                return allDay ? due < calendar.startOfDay(for: now) : due < now
            }
        }
    }

    /// The task's due day as `YYYY-MM-DD` in the calendar's time zone, which sorts the way days do.
    private static func day(_ date: Date?, _ calendar: Calendar) -> String? {
        guard let date else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// A named query the user picks to narrow the task list. The chat agent creates and edits these; the list shows them as chips.
public struct QuickFilter: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The query as JSON. Kept as written so a newer Mac's conditions survive a round trip through an older one.
    public var query: RemoteJSON
    /// Position among the chips, lowest first.
    public var order: Int

    public init(id: String, name: String, query: RemoteJSON, order: Int = 0) {
        self.id = id; self.name = name; self.query = query; self.order = order
    }

    /// The parsed query, or nil when this build does not understand it (a newer Mac wrote it). Such a filter is hidden, not applied.
    public var node: QuickFilterNode? { try? QuickFilterNode.parse(query.foundationValue) }

    public func matches<T: QuickFilterSubject>(_ task: T, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        node?.matches(task, now: now, calendar: calendar) ?? false
    }

    /// Chips in order, then by name. Filters this build cannot read are left out.
    public static func chips(_ filters: [QuickFilter]) -> [QuickFilter] {
        filters.filter { $0.node != nil }.sorted { ($0.order, $0.name.lowercased(), $0.id) < ($1.order, $1.name.lowercased(), $1.id) }
    }

    /// The query as compact JSON with sorted keys, for a prompt.
    public var queryText: String { query.compactText }
}

/// Chips the app adds itself. They are not stored, so the user cannot edit, move or remove them, and the agent never
/// writes them. Their ids and names are reserved, so a saved filter cannot take them.
public enum BuiltInQuickFilters {
    public static let nextActionsID = "next-actions"

    /// Open tasks (backlog, in progress, needs you) that nobody else holds.
    static let nextActionsQuery = #"{"and":[{"status":["backlog","in_progress","needs_you"]},{"waitingOn":null}]}"#

    public static let all: [QuickFilter] = [
        QuickFilter(id: nextActionsID, name: "Next actions", query: (try? JSONDecoder().decode(RemoteJSON.self, from: Data(nextActionsQuery.utf8))) ?? .null, order: -1),
    ]

    public static func isBuiltIn(_ id: String) -> Bool { all.contains { $0.id == id } }

    /// A name a saved filter may not take, compared without regard to case.
    public static func isReservedName(_ name: String) -> Bool { all.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
}

/// The body of `GET /v1/task-filters`.
public struct QuickFilterListResponse: Codable, Equatable, Sendable {
    public var filters: [QuickFilter]
    public init(filters: [QuickFilter]) { self.filters = filters }
}

/// The text "Add" and "Edit" send to the main chat. The agent owns the queries, so the app only asks.
public enum QuickFilterPrompt {
    public static func add(_ text: String) -> String {
        "Create a task quick filter: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    public static func edit(_ filter: QuickFilter, _ text: String) -> String {
        "Change the task quick filter \"\(filter.name)\" (id \(filter.id), current query \(filter.queryText)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

extension RemoteJSON {
    /// The value as `JSONSerialization` returns it, so `QuickFilterNode.parse` reads the same shapes as a tool call does.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        }
    }

    /// From a value `JSONSerialization` returned. Nil when it holds something that is not JSON.
    public init?(foundation value: Any) {
        switch value {
        case is NSNull: self = .null
        case let text as String: self = .string(text)
        case let number as NSNumber:
            if String(cString: number.objCType) == "c" { self = .bool(number.boolValue) }
            else if number.doubleValue == Double(number.intValue) { self = .int(number.intValue) }
            else { self = .double(number.doubleValue) }
        case let list as [Any]:
            let items = list.compactMap { RemoteJSON(foundation: $0) }
            guard items.count == list.count else { return nil }
            self = .array(items)
        case let object as [String: Any]:
            var items: [String: RemoteJSON] = [:]
            for (key, item) in object {
                guard let converted = RemoteJSON(foundation: item) else { return nil }
                items[key] = converted
            }
            self = .object(items)
        default: return nil
        }
    }

    /// Compact JSON with sorted keys.
    public var compactText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

/// The quick filter the Tasks list is narrowed by, kept in UserDefaults so it survives leaving the screen and a relaunch.
/// Each device keeps its own pick. Nil is the "All" chip.
public enum QuickFilterSelection {
    public static let key = "tasksQuickFilter"

    public static func load(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func save(_ id: String?, _ defaults: UserDefaults = .standard) {
        if let id, !id.isEmpty { defaults.set(id, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// `id` when a chip with that id exists, otherwise nil. A removed filter falls back to "All".
    public static func valid(_ id: String?, in filters: [QuickFilter]) -> String? {
        guard let id, QuickFilter.chips(filters).contains(where: { $0.id == id }) else { return nil }
        return id
    }
}
