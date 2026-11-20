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
}
