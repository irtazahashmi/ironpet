import Foundation

// The phase 5 resources: screen capture status, the change list, a capture's outline, search and pause. The Mac builds these from the
// JSON of the `screen_*` agent tools, which hold text that was redacted before it was stored and are filtered again on read.
// The phone keeps them in memory only.

/// `GET /v1/screen/status`.
public struct RemoteScreenStatus: Codable, Equatable, Sendable {
    public var running: Bool
    public var accessibility: Bool
    public var screenRecording: Bool
    public var paused: Bool
    public var pausedUntil: Date?
    public var captureCount: Int
    public var lastCapture: Date?

    enum CodingKeys: String, CodingKey {
        case running, accessibility, paused
        case screenRecording = "screen_recording"
        case pausedUntil = "paused_until"
        case captureCount = "capture_count"
        case lastCapture = "last_capture"
    }

    public init(running: Bool = false, accessibility: Bool = true, screenRecording: Bool = false, paused: Bool = false, pausedUntil: Date? = nil,
                captureCount: Int = 0, lastCapture: Date? = nil) {
        self.running = running; self.accessibility = accessibility; self.screenRecording = screenRecording; self.paused = paused
        self.pausedUntil = pausedUntil; self.captureCount = captureCount; self.lastCapture = lastCapture
    }
}

/// One window of the change list: its newest changes as the tool prints them, one string each.
public struct RemoteScreenWindow: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var app: String
    public var window: String
    /// The list that holds all of the changes, said once (`in` on the wire).
    public var container: String?
    public var changes: [String]
    public var url: String?
    /// How many older changes the cap left out.
    public var more: Int?

    public var id: String { "\(app)\u{1F}\(window)\u{1F}\(url ?? "")" }

    enum CodingKeys: String, CodingKey {
        case app, window, changes, url, more
        case container = "in"
    }

    public init(app: String, window: String, container: String? = nil, changes: [String], url: String? = nil, more: Int? = nil) {
        self.app = app; self.window = window; self.container = container; self.changes = changes; self.url = url; self.more = more
    }

    /// The capture id (`c12`) in the last field of a change line, which is how the phone opens the outline.
    public static func captureID(in line: String) -> Int? {
        for field in line.components(separatedBy: " | ").reversed() {
            for word in field.split(separator: " ") where word.hasPrefix("c") {
                if let id = Int(word.dropFirst()) { return id }
            }
        }
        return nil
    }
}

/// `GET /v1/screen/changes`.
public struct RemoteScreenChanges: Codable, Equatable, Sendable {
    public var changes: [RemoteScreenWindow]
    public init(changes: [RemoteScreenWindow] = []) { self.changes = changes }
}

/// One search hit: a capture and a short snippet around the match.
public struct RemoteScreenHit: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var time: Date
    public var app: String
    public var bundleID: String
    public var window: String
    public var snippet: String
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case id, time, app, window, snippet, url
        case bundleID = "bundle_id"
    }

    public init(id: Int, time: Date, app: String, bundleID: String = "", window: String, snippet: String, url: String? = nil) {
        self.id = id; self.time = time; self.app = app; self.bundleID = bundleID; self.window = window; self.snippet = snippet; self.url = url
    }
}

/// `GET /v1/screen/search`.
public struct RemoteScreenSearch: Codable, Equatable, Sendable {
    public var count: Int
    public var hits: [RemoteScreenHit]
    public init(count: Int = 0, hits: [RemoteScreenHit] = []) { self.count = count; self.hits = hits }
}

/// One capture: its text when it was read from pixels, or the outline (or the elements of a role) of its window tree.
public struct RemoteScreenCapture: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var time: Date
    public var app: String
    public var bundleID: String
    public var window: String
    public var trigger: String
    public var url: String?
    /// Only for a capture without a window tree.
    public var text: String?
    public var root: String?
    public var role: String?
    public var outline: String?
    public var elements: String?

    enum CodingKeys: String, CodingKey {
        case id, time, app, window, trigger, url, text, root, role, outline, elements
        case bundleID = "bundle_id"
    }

    public init(id: Int, time: Date, app: String, bundleID: String = "", window: String, trigger: String = "", url: String? = nil,
                text: String? = nil, root: String? = nil, role: String? = nil, outline: String? = nil, elements: String? = nil) {
        self.id = id; self.time = time; self.app = app; self.bundleID = bundleID; self.window = window; self.trigger = trigger; self.url = url
        self.text = text; self.root = root; self.role = role; self.outline = outline; self.elements = elements
    }
}

/// `GET /v1/screen/captures/<id>`.
public struct RemoteScreenCaptureResponse: Codable, Equatable, Sendable {
    public var capture: RemoteScreenCapture
    public init(capture: RemoteScreenCapture) { self.capture = capture }
}
