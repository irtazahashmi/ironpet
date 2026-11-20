import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case backlog
    case inProgress = "in_progress"
    case needsYou = "needs_you"
    case done

    public var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .inProgress: return "In progress"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        }
    }
}

public struct TaskLink: Codable, Equatable, Hashable, Sendable {
    public var kind: String
    public var ref: String
    public var label: String?
}

/// A task as `TaskJSON.json(_:)` writes it on the Mac: snake_case keys, ISO 8601 dates, empty fields left out.
public struct RemoteTask: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var status: TaskStatus
    public var source: String
    public var due: Date?
    public var closed: Date?
    public var waitingOn: String?
    public var links: [TaskLink]
    public var labels: [String: String]
    public var created: Date
    public var updated: Date

    enum CodingKeys: String, CodingKey {
        case id, title, notes, status, source, due, closed, links, labels, created, updated
        case waitingOn = "waiting_on"
    }

    public init(id: String, title: String, notes: String = "", status: TaskStatus = .backlog, source: String = "user", due: Date? = nil,
                closed: Date? = nil, waitingOn: String? = nil, links: [TaskLink] = [], labels: [String: String] = [:],
                created: Date = Date(timeIntervalSince1970: 1_700_000_000), updated: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.id = id; self.title = title; self.notes = notes; self.status = status; self.source = source; self.due = due
        self.closed = closed; self.waitingOn = waitingOn; self.links = links; self.labels = labels; self.created = created; self.updated = updated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        status = try c.decode(TaskStatus.self, forKey: .status)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "user"
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        closed = try c.decodeIfPresent(Date.self, forKey: .closed)
        waitingOn = try c.decodeIfPresent(String.self, forKey: .waitingOn)
        links = try c.decodeIfPresent([TaskLink].self, forKey: .links) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        created = try c.decode(Date.self, forKey: .created)
        updated = try c.decode(Date.self, forKey: .updated)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
        try c.encode(status, forKey: .status)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(due, forKey: .due)
        try c.encodeIfPresent(closed, forKey: .closed)
        try c.encodeIfPresent(waitingOn, forKey: .waitingOn)
        if !links.isEmpty { try c.encode(links, forKey: .links) }
        if !labels.isEmpty { try c.encode(labels, forKey: .labels) }
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
    }

    /// Only the user can take the next step. A task waiting on someone else never counts, whatever its status.
    public var needsUser: Bool { status == .needsYou && waitingOn == nil }
}

public struct RemoteTaskEvent: Codable, Equatable, Hashable, Sendable {
    public var at: Date
    public var by: String
    public var kind: String
    public var detail: String

    public init(at: Date, by: String, kind: String, detail: String) {
        self.at = at; self.by = by; self.kind = kind; self.detail = detail
    }
}

/// `GET /v1/tasks/:id`: the task's own keys with its history beside them.
public struct RemoteTaskDetail: Codable, Equatable, Sendable {
    public var task: RemoteTask
    public var history: [RemoteTaskEvent]

    enum CodingKeys: String, CodingKey { case history }

    public init(task: RemoteTask, history: [RemoteTaskEvent]) { self.task = task; self.history = history }

    public init(from decoder: Decoder) throws {
        task = try RemoteTask(from: decoder)
        history = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([RemoteTaskEvent].self, forKey: .history) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        try task.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(history, forKey: .history)
    }
}

public struct RemoteSuggestion: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var created: Date
    /// `meeting` or `automation`.
    public var origin: String
    public var originDetail: String?
    /// Free text from a meeting ("Friday") or `yyyy-MM-dd`.
    public var due: String?
    public var notes: String
    public var url: String?
    public var waitingOn: String?

    enum CodingKeys: String, CodingKey {
        case id, title, created, origin, due, notes, url
        case originDetail = "origin_detail"
        case waitingOn = "waiting_on"
    }

    public init(id: String, title: String, created: Date = Date(timeIntervalSince1970: 1_700_000_000), origin: String = "meeting",
                originDetail: String? = nil, due: String? = nil, notes: String = "", url: String? = nil, waitingOn: String? = nil) {
        self.id = id; self.title = title; self.created = created; self.origin = origin; self.originDetail = originDetail
        self.due = due; self.notes = notes; self.url = url; self.waitingOn = waitingOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        created = try c.decode(Date.self, forKey: .created)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        originDetail = try c.decodeIfPresent(String.self, forKey: .originDetail)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        waitingOn = try c.decodeIfPresent(String.self, forKey: .waitingOn)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(created, forKey: .created)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(originDetail, forKey: .originDetail)
        try c.encodeIfPresent(due, forKey: .due)
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(waitingOn, forKey: .waitingOn)
    }
}

public struct TaskListResponse: Codable, Equatable, Sendable {
    public var tasks: [RemoteTask]
    public init(tasks: [RemoteTask]) { self.tasks = tasks }
}

public struct SuggestionListResponse: Codable, Equatable, Sendable {
    public var suggestions: [RemoteSuggestion]
    public init(suggestions: [RemoteSuggestion]) { self.suggestions = suggestions }
}

/// `GET /v1/devices/me`.
public struct RemoteDevice: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var created: Date
    public var lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, created
        case lastSeen = "last_seen"
    }

    public init(id: String, name: String, created: Date = Date(timeIntervalSince1970: 1_700_000_000), lastSeen: Date? = nil) {
        self.id = id; self.name = name; self.created = created; self.lastSeen = lastSeen
    }
}

/// One frame of the event socket: `{"kind":"hello","seq":n}`, `{"kind":"resync","seq":n}` or an `APIEvent` (`seq`, `at`, `kind`, `id`).
public struct RemoteEvent: Codable, Equatable, Sendable {
    public static let hello = "hello"
    public static let resync = "resync"
    public static let tasksChanged = "tasks.changed"
    public static let suggestionsChanged = "suggestions.changed"
    public static let petMood = "pet.mood"
    public static let bubbleShown = "bubble.shown"
    public static let bubbleDismissed = "bubble.dismissed"
    public static let assetsChanged = "assets.changed"
    public static let agentsChanged = "agents.changed"
    public static let alertsChanged = "alerts.changed"
    /// A chat message was added or changed. `id` is the message's id; no id means read the chat again.
    public static let chatItem = "chat.item"
    /// What else moved in the chat: `approvals`, `forms`, `queue`, `draft`, or no id for the turn state.
    public static let chatState = "chat.state"

    public var seq: Int
    public var at: Date?
    public var kind: String
    public var id: String?

    public init(seq: Int, kind: String, at: Date? = nil, id: String? = nil) {
        self.seq = seq; self.kind = kind; self.at = at; self.id = id
    }
}

// MARK: Pairing

public struct PairRequest: Codable, Equatable, Sendable {
    public var code: String
    public var deviceName: String

    enum CodingKeys: String, CodingKey {
        case code
        case deviceName = "device_name"
    }

    public init(code: String, deviceName: String) { self.code = code; self.deviceName = deviceName }
}

public struct PairAccepted: Codable, Equatable, Sendable {
    public var pairingID: String
    public var secret: String
    public var expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case secret
        case pairingID = "pairing_id"
        case expiresIn = "expires_in"
    }

    public init(pairingID: String, secret: String, expiresIn: Int = 300) {
        self.pairingID = pairingID; self.secret = secret; self.expiresIn = expiresIn
    }
}

public struct PairPoll: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, denied, expired, allowed }
    public var status: Status
    public var token: String?
    public var deviceID: String?

    enum CodingKeys: String, CodingKey {
        case status, token
        case deviceID = "device_id"
    }

    public init(status: Status, token: String? = nil, deviceID: String? = nil) {
        self.status = status; self.token = token; self.deviceID = deviceID
    }
}

/// `{"error":{"code","message"}}`.
public struct APIErrorBody: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public var code: String
        public var message: String
        public init(code: String, message: String) { self.code = code; self.message = message }
    }
    public var error: Detail
    public init(error: Detail) { self.error = error }
}

public enum WireJSON {
    /// Dates on the wire are `ISO8601DateFormatter` output: no fractional seconds. A fractional form is accepted too.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter().string(from: date))
        }
        return encoder
    }

    static func parse(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
