import Foundation
#if canImport(Combine)
import Combine
#endif

package struct ScreenSearchRequest: Codable, Equatable {
    package init(query: String, app: String? = nil, since: Date? = nil, until: Date? = nil, limit: Int = 20) {
        self.query = query
        self.app = app
        self.since = since
        self.until = until
        self.limit = limit
    }

    package var query: String
    /// Only this app, by bundle id or name.
    package var app: String?
    package var since: Date?
    package var until: Date?
    package var limit = 20
}

/// What screen capture stored: the local text of windows the user worked in, with secrets already redacted. Nothing here reads
/// the screen. Turning capture on or off is a setting (`api.settings`); pausing it is here.
///
/// This is an `ObservableObject` on Apple platforms, so the Screen section and its settings page redraw as captures arrive.
@MainActor
package final class ScreenAPI {
    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    private let control: CaptureControl
    private var forwarding: [ChangeToken] = []

    package init(control: CaptureControl) {
        self.control = control
        forwarding = [
            control.model.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    /// Whether capture runs, what macOS allows it, whether it is paused, how many captures are stored.
    package var status: CaptureStatusModel { control.model }

    /// Reads the state again, for example after the user changed a permission.
    package func refreshStatus() { control.refreshModel() }

    package func recent(limit: Int = 50) async -> [StoredCapture] {
        let control = control
        return await Task.detached(priority: .userInitiated) { control.recentCaptures(limit: limit) }.value
    }

    package func search(_ request: ScreenSearchRequest) async throws -> [CaptureHit] {
        let query = request.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { throw APIError.invalid("query is required") }
        let control = control
        return await Task.detached(priority: .userInitiated) {
            control.searchCaptures(query, app: request.app, since: request.since, until: request.until, limit: request.limit)
        }.value
    }

    /// The text stored for one capture. Nil when it was deleted.
    package func captureText(_ id: Int64) async -> String? {
        let control = control
        return await Task.detached(priority: .userInitiated) { control.captureText(id) }.value
    }

    /// The apps captured so far, with how many captures each has, for the exclude list.
    package func seenApps() -> [(bundleId: String, name: String, captures: Int)] { control.seenApps() }

    package func pause(for seconds: TimeInterval) throws {
        guard seconds > 0 else { throw APIError.invalid("the pause must be longer than zero") }
        do { try control.pause(for: seconds) } catch { throw APIError.unavailable(error.localizedDescription) }
    }

    package func pauseUntilTomorrow() { try? control.pauseUntilTomorrow() }

    package func resume() { try? control.resume() }

    /// Deletes every stored capture.
    package func clear() { try? control.clearCaptures() }

    /// The MCP tools `screen_search` and `screen_window`, which read loose JSON arguments.
    package func callTool(_ name: String, _ args: [String: Any]) -> Result<Any, ScreenMCP.Failure> {
        control.callTool(name, args)
    }
}

#if canImport(Combine)

extension ScreenAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
