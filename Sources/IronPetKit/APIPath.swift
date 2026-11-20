import Foundation

/// The routes of the remote API (SPEC.md > Remote API). The Mac's `RemoteServer` registers the same strings.
public enum APIPath {
    public static let pair = "/v1/pair"
    public static func pairStatus(_ id: String) -> String { "/v1/pair/\(id)" }
    public static let deviceMe = "/v1/devices/me"
    public static let tasks = "/v1/tasks"
    public static func task(_ id: String) -> String { "/v1/tasks/\(id)" }
    public static func closeTask(_ id: String) -> String { "/v1/tasks/\(id)/close" }
    public static let suggestions = "/v1/suggestions"
    public static func acceptSuggestion(_ id: String) -> String { "/v1/suggestions/\(id)/accept" }
    /// The Mac calls Skip "reject".
    public static func rejectSuggestion(_ id: String) -> String { "/v1/suggestions/\(id)/reject" }
    public static let events = "/v1/events"
    public static let pet = "/v1/pet"
    public static func trick(_ name: String) -> String { "/v1/pet/tricks/\(name)" }
    public static let bubbles = "/v1/bubbles"
    public static func bubbleAction(_ bubble: String, _ action: String) -> String { "/v1/bubbles/\(bubble)/actions/\(action)" }
    public static let agents = "/v1/agents"
    public static func agent(_ id: String) -> String { "/v1/agents/\(id)" }
    public static func acknowledgeAgent(_ id: String) -> String { "/v1/agents/\(id)/acknowledge" }
    public static func askAboutAgent(_ id: String) -> String { "/v1/agents/\(id)/ask" }
    public static let alerts = "/v1/alerts"
    public static let dismissAllAlerts = "/v1/alerts/dismiss-all"
    public static func dismissAlert(_ id: String) -> String { "/v1/alerts/\(id)/dismiss" }
    public static func askAboutAlert(_ id: String) -> String { "/v1/alerts/\(id)/ask" }
    public static let today = "/v1/today"
    public static let assetManifest = "/v1/assets/manifest"
    public static func asset(_ sha256: String) -> String { "/v1/assets/\(sha256)" }
}
