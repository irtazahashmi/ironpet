import Foundation

public struct TaskLink: Codable, Equatable, Hashable, Sendable {
    public var kind: String
    public var ref: String
    public var label: String?

    public init(kind: String, ref: String, label: String? = nil) { self.kind = kind; self.ref = ref; self.label = label }
}

/// One place an inbox item came from. An item that was merged lists each.
public struct RemoteSource: Codable, Equatable, Hashable, Sendable {
    public var kind: String
    public var ref: String
    public var url: String?
    public var label: String?

    public init(kind: String, ref: String, url: String? = nil, label: String? = nil) {
        self.kind = kind; self.ref = ref; self.url = url; self.label = label
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
    public var sourceRef: RemoteJSON?
    /// Every place the item came from. An older Mac sends none, and the phone falls back to `url`.
    public var sources: [RemoteSource]

    enum CodingKeys: String, CodingKey {
        case id, title, created, origin, due, notes, url, sources
        case originDetail = "origin_detail"
        case waitingOn = "waiting_on"
        case sourceRef = "source_ref"
    }

    public init(id: String, title: String, created: Date = Date(timeIntervalSince1970: 1_700_000_000), origin: String = "meeting",
                originDetail: String? = nil, due: String? = nil, notes: String = "", url: String? = nil, waitingOn: String? = nil,
                sourceRef: RemoteJSON? = nil, sources: [RemoteSource] = []) {
        self.sources = sources
        self.id = id; self.title = title; self.created = created; self.origin = origin; self.originDetail = originDetail
        self.due = due; self.notes = notes; self.url = url; self.waitingOn = waitingOn; self.sourceRef = sourceRef
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
        sourceRef = try c.decodeIfPresent(RemoteJSON.self, forKey: .sourceRef)
        sources = try c.decodeIfPresent([RemoteSource].self, forKey: .sources) ?? []
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
        try c.encodeIfPresent(sourceRef, forKey: .sourceRef)
        if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
    }
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
    /// The Mac replayed every event after the `since` the phone sent. `seq` is where the live stream continues.
    public static let resumed = "resumed"
    public static let suggestionsChanged = "suggestions.changed"
    public static let petMood = "pet.mood"
    public static let bubbleShown = "bubble.shown"
    public static let bubbleDismissed = "bubble.dismissed"
    public static let assetsChanged = "assets.changed"
    public static let agentsChanged = "agents.changed"
    public static let alertsChanged = "alerts.changed"
    public static let automationsChanged = "automations.changed"
    /// A dashboard was added, edited, approved, removed or fed new data. `id` is the dashboard.
    public static let dashboardsChanged = "dashboards.changed"
    public static let automationNeedsApproval = "automation.needsApproval"
    public static let meetingsChanged = "meetings.changed"
    public static let settingsChanged = "settings.changed"
    /// A chat message was added or changed. `id` is the message's id; no id means read the chat again.
    public static let chatItem = "chat.item"
    /// What else moved in the chat: `approvals`, `forms`, `queue`, `draft`, or no id for the turn state.
    public static let chatState = "chat.state"

    public var seq: Int
    public var at: Date?
    public var kind: String
    public var id: String?
    /// For chat events: the agent whose chat changed. Nil is agent 1, and is all an older Mac sends.
    public var agentId: String?
    /// For `chat.item`: the message as it is now, when the Mac sends it along. Nil from an older Mac, or when the text is too long
    /// to send, and the phone reads the message with a GET.
    public var item: RemoteChatItem?

    public init(seq: Int, kind: String, at: Date? = nil, id: String? = nil, item: RemoteChatItem? = nil, agentId: String? = nil) {
        self.seq = seq; self.kind = kind; self.at = at; self.id = id; self.item = item; self.agentId = agentId
    }

    enum CodingKeys: String, CodingKey { case seq, at, kind, id, item, agentId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        at = try? c.decodeIfPresent(Date.self, forKey: .at)
        kind = try c.decode(String.self, forKey: .kind)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        // A message this app cannot read must not drop the event: the phone falls back to reading it.
        item = try? c.decodeIfPresent(RemoteChatItem.self, forKey: .item)
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
