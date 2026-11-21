import Foundation

/// The phase 5 calls: screen capture. They need the `screen` scope, which the user grants per device on the Mac. Without it the Mac
/// answers 403, and `ClientError.api(status: 403, ...)` carries the reason.
extension IronPetClient {
    public func screenStatus() async throws -> RemoteScreenStatus { try await get(RemoteScreenStatus.self, APIPath.screenStatus) }

    /// The change list from `since` (`today`, `2h`, `2026-11-18`) to `until`, grouped by window.
    public func screenChanges(since: String, until: String? = nil, app: String? = nil, window: String? = nil) async throws -> [RemoteScreenWindow] {
        var query = [URLQueryItem(name: "since", value: since)]
        if let until { query.append(URLQueryItem(name: "until", value: until)) }
        if let app { query.append(URLQueryItem(name: "app", value: app)) }
        if let window { query.append(URLQueryItem(name: "window", value: window)) }
        return try await get(RemoteScreenChanges.self, APIPath.screenChanges, query: query).changes
    }

    /// The outline of a capture's window, of the subtree `root`, or the elements with `role`.
    public func screenCapture(id: Int, root: String? = nil, role: String? = nil, text: String? = nil, depth: Int? = nil) async throws -> RemoteScreenCapture {
        var query: [URLQueryItem] = []
        if let root { query.append(URLQueryItem(name: "root", value: root)) }
        if let role { query.append(URLQueryItem(name: "role", value: role)) }
        if let text { query.append(URLQueryItem(name: "text", value: text)) }
        if let depth { query.append(URLQueryItem(name: "depth", value: String(depth))) }
        return try await get(RemoteScreenCaptureResponse.self, APIPath.screenCapture(id), query: query).capture
    }

    public func screenSearch(_ query: String, app: String? = nil, since: String? = nil, until: String? = nil, limit: Int? = nil) async throws -> [RemoteScreenHit] {
        var items = [URLQueryItem(name: "q", value: query)]
        if let app { items.append(URLQueryItem(name: "app", value: app)) }
        if let since { items.append(URLQueryItem(name: "since", value: since)) }
        if let until { items.append(URLQueryItem(name: "until", value: until)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(RemoteScreenSearch.self, APIPath.screenSearch, query: items).hits
    }

    /// Pauses capture for `minutes`, or until tomorrow. Only pausing is possible from the phone; resuming happens on the Mac.
    @discardableResult
    public func pauseScreen(minutes: Int) async throws -> RemoteScreenStatus {
        try await post(RemoteScreenStatus.self, APIPath.screenPause, json: ["minutes": minutes])
    }

    @discardableResult
    public func pauseScreenUntilTomorrow() async throws -> RemoteScreenStatus {
        try await post(RemoteScreenStatus.self, APIPath.screenPause, json: ["until": "tomorrow"])
    }
}
