import Foundation

// The phase 2 resources: the pet, its bubbles, agent sessions, alerts, the brief and recap, and the asset manifest. Keys are the
// snake_case ones `RemoteResources` writes on the Mac.

/// `GET /v1/pet`.
public struct RemotePet: Codable, Equatable, Sendable {
    public var name: String
    public var mood: String
    public var badge: Int
    public var tricks: [String]
    /// A built-in id (`default`, `dusk`, ...) or `custom`.
    public var background: String
    /// `pet.sprite` when the Mac has a sheet to download.
    public var sprite: String?
    public var backgroundAsset: String?

    enum CodingKeys: String, CodingKey {
        case name, mood, badge, tricks, background, sprite
        case backgroundAsset = "background_asset"
    }

    public init(name: String, mood: String = "idle", badge: Int = 0, tricks: [String] = [], background: String = "default",
                sprite: String? = "pet.sprite", backgroundAsset: String? = nil) {
        self.name = name; self.mood = mood; self.badge = badge; self.tricks = tricks; self.background = background
        self.sprite = sprite; self.backgroundAsset = backgroundAsset
    }
}

public struct RemoteBubbleAction: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// `primary`, `normal` or `destructive`.
    public var style: String
    public init(id: String, title: String, style: String = "normal") { self.id = id; self.title = title; self.style = style }
}

public struct RemoteBubble: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var symbol: String
    public var title: String
    public var subtitle: String?
    public var body: String?
    public var lines: [String]
    public var actions: [RemoteBubbleAction]
    /// The buttons are the Mac's to press. `actions` is empty and the phone says "Answer on the Mac".
    public var macOnly: Bool
    public var expires: Date?

    enum CodingKeys: String, CodingKey {
        case id, symbol, title, subtitle, body, lines, actions, expires
        case macOnly = "mac_only"
    }

    public init(id: String, symbol: String = "bubble.left.fill", title: String, subtitle: String? = nil, body: String? = nil, lines: [String] = [],
                actions: [RemoteBubbleAction] = [], macOnly: Bool = false, expires: Date? = nil) {
        self.id = id; self.symbol = symbol; self.title = title; self.subtitle = subtitle; self.body = body; self.lines = lines
        self.actions = actions; self.macOnly = macOnly; self.expires = expires
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "bubble.left.fill"
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        actions = try c.decodeIfPresent([RemoteBubbleAction].self, forKey: .actions) ?? []
        macOnly = try c.decodeIfPresent(Bool.self, forKey: .macOnly) ?? false
        expires = try c.decodeIfPresent(Date.self, forKey: .expires)
    }
}

public struct BubbleListResponse: Codable, Equatable, Sendable {
    public var bubbles: [RemoteBubble]
    public init(bubbles: [RemoteBubble]) { self.bubbles = bubbles }
}

public enum AgentStatusName: String, Codable, Sendable {
    case idle, running, done, failed
    case needsInput = "needs_input"
}

/// `GET /v1/agents` and `GET /v1/agents/:id`. `lastResponse` comes only with the detail.
public struct RemoteAgent: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var source: String
    public var sourceName: String
    public var status: AgentStatusName
    public var statusLabel: String
    public var workspace: String
    public var prompt: String?
    public var detail: String?
    public var summary: String?
    public var editedFiles: [String]
    public var updated: Date
    public var lastResponse: String?

    enum CodingKeys: String, CodingKey {
        case id, source, status, workspace, prompt, detail, summary, updated
        case sourceName = "source_name"
        case statusLabel = "status_label"
        case editedFiles = "edited_files"
        case lastResponse = "last_response"
    }

    public init(id: String, source: String = "claude", sourceName: String = "Claude Code", status: AgentStatusName = .running,
                statusLabel: String = "Running", workspace: String, prompt: String? = nil, detail: String? = nil, summary: String? = nil,
                editedFiles: [String] = [], updated: Date = Date(timeIntervalSince1970: 1_700_000_000), lastResponse: String? = nil) {
        self.id = id; self.source = source; self.sourceName = sourceName; self.status = status; self.statusLabel = statusLabel
        self.workspace = workspace; self.prompt = prompt; self.detail = detail; self.summary = summary; self.editedFiles = editedFiles
        self.updated = updated; self.lastResponse = lastResponse
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? source
        status = try c.decode(AgentStatusName.self, forKey: .status)
        statusLabel = try c.decodeIfPresent(String.self, forKey: .statusLabel) ?? status.rawValue
        workspace = try c.decode(String.self, forKey: .workspace)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        editedFiles = try c.decodeIfPresent([String].self, forKey: .editedFiles) ?? []
        updated = try c.decode(Date.self, forKey: .updated)
        lastResponse = try c.decodeIfPresent(String.self, forKey: .lastResponse)
    }

    /// Done and failed sessions wait to be acknowledged.
    public var canAcknowledge: Bool { status == .done || status == .failed }
}

public struct AgentListResponse: Codable, Equatable, Sendable {
    public var agents: [RemoteAgent]
    public init(agents: [RemoteAgent]) { self.agents = agents }
}

public struct RemoteAlert: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var label: String
    public var symbol: String
    public var mood: String
    public var date: Date
    public var canAsk: Bool
    public var url: String?
    public var detail: String?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, label, symbol, mood, date, url, detail
        case canAsk = "can_ask"
    }

    public init(id: String, title: String, subtitle: String = "", label: String = "Alert", symbol: String = "exclamationmark.triangle.fill",
                mood: String = "needsInput", date: Date = Date(timeIntervalSince1970: 1_700_000_000), canAsk: Bool = true, url: String? = nil,
                detail: String? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.label = label; self.symbol = symbol; self.mood = mood
        self.date = date; self.canAsk = canAsk; self.url = url; self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "exclamationmark.triangle.fill"
        mood = try c.decodeIfPresent(String.self, forKey: .mood) ?? "needsInput"
        date = try c.decode(Date.self, forKey: .date)
        canAsk = try c.decodeIfPresent(Bool.self, forKey: .canAsk) ?? false
        url = try c.decodeIfPresent(String.self, forKey: .url)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

public struct AlertListResponse: Codable, Equatable, Sendable {
    public var alerts: [RemoteAlert]
    public init(alerts: [RemoteAlert]) { self.alerts = alerts }
}

/// What a Today item opens. `task`, `session`, `alert` and `meeting` map to the Tasks, Agents, Alerts tabs and the Mac's transcripts.
public struct TodayTarget: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case task, session, alert, meeting }
    public var type: Kind
    public var id: String
    public var url: String?
    public init(type: Kind, id: String, url: String? = nil) { self.type = type; self.id = id; self.url = url }
}

public struct TodayItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var symbol: String
    public var title: String
    public var subtitle: String?
    public var target: TodayTarget
    public init(id: String, symbol: String = "circle", title: String, subtitle: String? = nil, target: TodayTarget) {
        self.id = id; self.symbol = symbol; self.title = title; self.subtitle = subtitle; self.target = target
    }
}

public struct TodaySection: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var items: [TodayItem]
    public init(id: String, title: String, items: [TodayItem]) { self.id = id; self.title = title; self.items = items }
}

/// `GET /v1/today?kind=brief|recap`.
public struct RemoteToday: Codable, Equatable, Sendable {
    public var kind: String
    public var title: String
    public var lines: [String]
    public var sections: [TodaySection]
    public init(kind: String, title: String, lines: [String] = [], sections: [TodaySection]) {
        self.kind = kind; self.title = title; self.lines = lines; self.sections = sections
    }
    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }
}

/// One file in `GET /v1/assets/manifest`. `sha256` names it for `GET /v1/assets/<sha256>`.
public struct RemoteAsset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var name: String
    public var sha256: String
    public var bytes: Int
    public var contentType: String
    public var width: Int?
    public var height: Int?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, sha256, bytes, width, height
        case contentType = "content_type"
    }

    public init(id: String, kind: String = "spritesheet", name: String = "", sha256: String, bytes: Int = 0, contentType: String = "image/png",
                width: Int? = nil, height: Int? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.sha256 = sha256; self.bytes = bytes; self.contentType = contentType
        self.width = width; self.height = height
    }
}

public struct AssetManifestResponse: Codable, Equatable, Sendable {
    public var assets: [RemoteAsset]
    public init(assets: [RemoteAsset]) { self.assets = assets }
}

// MARK: Acknowledgements

// The one-field answers of the action routes. Each names what the call changed.

/// `POST /v1/pet/tricks/<name>`.
public struct RemoteTrickResult: Codable, Equatable, Sendable {
    public var performed: String
    public init(performed: String) { self.performed = performed }
}

/// `POST /v1/bubbles/<id>/actions/<action>`.
public struct RemoteBubblePress: Codable, Equatable, Sendable {
    public var pressed: String
    public init(pressed: String) { self.pressed = pressed }
}

/// `POST /v1/agents/<id>/acknowledge`.
public struct RemoteAcknowledged: Codable, Equatable, Sendable {
    public var acknowledged: String
    public init(acknowledged: String) { self.acknowledged = acknowledged }
}

/// `POST /v1/alerts/<id>/dismiss`.
public struct RemoteDismissed: Codable, Equatable, Sendable {
    public var dismissed: String
    public init(dismissed: String) { self.dismissed = dismissed }
}

/// `POST /v1/alerts/dismiss-all`: how many alerts were dismissed.
public struct RemoteDismissedCount: Codable, Equatable, Sendable {
    public var dismissed: Int
    public init(dismissed: Int) { self.dismissed = dismissed }
}

/// `DELETE /v1/tasks/<id>`.
public struct RemoteDeleted: Codable, Equatable, Sendable {
    public var deleted: String
    public init(deleted: String) { self.deleted = deleted }
}

/// `POST /v1/suggestions/<id>/reject`.
public struct RemoteRejected: Codable, Equatable, Sendable {
    public var rejected: String
    public init(rejected: String) { self.rejected = rejected }
}
