import Foundation

// User-defined dashboards on the wire. The Mac runs a dashboard's script and sends the phone the finished view, a tree of these
// nodes, so the phone draws it with native components and never runs the script. Keys are the snake_case ones `RemoteWire` writes.

/// One element of a dashboard's view. `type` is one of `column`, `row`, `card`, `text`, `stat`, `list`, `item`, `table`,
/// `chart`, `button`, `divider`. A client draws the types it knows and skips the rest, so a newer Mac can add one.
public struct DashboardNode: Codable, Equatable, Hashable, Sendable {
    public var type: String
    /// The content of a `text`, or the title of a `card`, `chart` or `item`.
    public var text: String?
    /// `title`, `heading`, `caption` or `code` for a `text`.
    public var style: String?
    /// The label of a `stat` or a `button`.
    public var label: String?
    /// The number or short value of a `stat`.
    public var value: String?
    public var caption: String?
    /// `good`, `warn`, `bad` or `info`. Nil is the neutral colour.
    public var tone: String?
    /// A short tag on an `item`, such as "Draft" or "#376".
    public var badge: String?
    /// An SF Symbol name on a `button` or an `item`.
    public var symbol: String?
    /// Table column headings.
    public var columns: [String]?
    public var rows: [[String]]?
    /// The values of a `chart`, drawn in order, and the label under each one.
    public var points: [Double]?
    public var labels: [String]?
    /// `line` or `bar`.
    public var chart: String?
    /// The id of the handler a click runs. A client sends it back to `dashboards.click`. Nil means the element does nothing.
    public var action: String?
    public var children: [DashboardNode]?

    public init(type: String, text: String? = nil, style: String? = nil, label: String? = nil, value: String? = nil, caption: String? = nil,
                tone: String? = nil, badge: String? = nil, symbol: String? = nil, columns: [String]? = nil, rows: [[String]]? = nil,
                points: [Double]? = nil, labels: [String]? = nil, chart: String? = nil, action: String? = nil, children: [DashboardNode]? = nil) {
        self.type = type; self.text = text; self.style = style; self.label = label; self.value = value; self.caption = caption
        self.tone = tone; self.badge = badge; self.symbol = symbol; self.columns = columns; self.rows = rows; self.points = points
        self.labels = labels; self.chart = chart; self.action = action; self.children = children
    }
}

/// One thing a dashboard asks to do, as the approval sheet lists it.
public struct RemoteDashboardCapability: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// `run`, `network`, `read`, `write` or `prompt`.
    public var kind: String
    public var title: String
    public var detail: String
    /// Not approved yet. The sheet marks these "New" when the dashboard was approved before.
    public var isNew: Bool

    public var id: String { kind }

    enum CodingKeys: String, CodingKey {
        case kind, title, detail
        case isNew = "is_new"
    }

    public init(kind: String, title: String, detail: String, isNew: Bool = false) {
        self.kind = kind; self.title = title; self.detail = detail; self.isNew = isNew
    }
}

/// A dashboard in the list: what the sidebar row or the More tab shows.
public struct RemoteDashboard: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// An SF Symbol name.
    public var icon: String
    /// A system colour name: `blue`, `indigo`, `purple`, `pink`, `red`, `orange`, `yellow`, `green`, `teal` or `gray`.
    public var color: String
    public var showsCount: Bool
    /// The number on the icon. Nil when the dashboard shows none or has none yet.
    public var count: Int?
    /// `approved`, or `pending` while something it declares waits for the user on the Mac.
    public var approval: String
    public var capabilities: [RemoteDashboardCapability]

    enum CodingKeys: String, CodingKey {
        case id, title, icon, color, count, approval, capabilities
        case showsCount = "shows_count"
    }

    public init(id: String, title: String, icon: String, color: String = "blue", showsCount: Bool = false, count: Int? = nil,
                approval: String = "approved", capabilities: [RemoteDashboardCapability] = []) {
        self.id = id; self.title = title; self.icon = icon; self.color = color; self.showsCount = showsCount; self.count = count
        self.approval = approval; self.capabilities = capabilities
    }
}

public struct DashboardListResponse: Codable, Equatable, Sendable {
    public var dashboards: [RemoteDashboard]
    public init(dashboards: [RemoteDashboard]) { self.dashboards = dashboards }
}

/// What a dashboard looks like now: the tree its script built from its data, or the reason it could not.
public struct RemoteDashboardView: Codable, Equatable, Sendable {
    public var dashboard: RemoteDashboard
    public var root: DashboardNode?
    /// Why the script failed, in words for the person. Nil when `root` is set.
    public var error: String?
    public var updated: Date?

    public init(dashboard: RemoteDashboard, root: DashboardNode? = nil, error: String? = nil, updated: Date? = nil) {
        self.dashboard = dashboard; self.root = root; self.error = error; self.updated = updated
    }
}

/// What a click did. The Mac already carried out a prompt and a data change. A client carries out the rest it can.
public struct RemoteDashboardClick: Codable, Equatable, Sendable {
    /// `open` (a link), `file` (a path on the Mac), `chat` (show the chat), each with `value`.
    public var effects: [RemoteDashboardEffect]
    public var error: String?
    public init(effects: [RemoteDashboardEffect] = [], error: String? = nil) { self.effects = effects; self.error = error }
}

public struct RemoteDashboardEffect: Codable, Equatable, Hashable, Sendable {
    public var kind: String
    public var value: String?
    public init(kind: String, value: String? = nil) { self.kind = kind; self.value = value }
}

/// The colours a dashboard can pick, in the order the picker lists them.
public enum DashboardColors {
    public static let names = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray"]
}
