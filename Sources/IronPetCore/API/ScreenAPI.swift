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

/// One capture a client read on its own screen. The client already redacted it: secrets, card numbers and the like are gone before the
/// text leaves the client. The core still runs its own redactor on what it stores, as it does for a capture it takes itself, but it
/// cannot tell what a client left out, so `redacted` must say the client did its part.
package struct ClientCapture: Codable, Equatable {
    package init(app: String, appName: String, title: String? = nil, url: String? = nil, trigger: String, lines: [String],
                 inputLines: [String]? = nil, at: Date? = nil, redacted: Bool) {
        self.app = app
        self.appName = appName
        self.title = title
        self.url = url
        self.trigger = trigger
        self.lines = lines
        self.inputLines = inputLines
        self.at = at
        self.redacted = redacted
    }

    /// The app's bundle id, or its package name on a client with no bundles.
    package var app: String
    package var appName: String
    package var title: String?
    package var url: String?
    /// Why it was taken: a `CaptureTrigger` name such as `app_switch` or `idle`.
    package var trigger: String
    package var lines: [String]
    /// Lines the person typed into fields, kept apart because they are a draft, not page text.
    package var inputLines: [String]?
    /// When the client read the window. The host's clock when nil.
    package var at: Date?
    /// The client redacted `lines` and `inputLines`. A capture that says false is refused.
    package var redacted: Bool
}

package struct ScreenIngestRequest: Codable, Equatable {
    package init(captures: [ClientCapture]) { self.captures = captures }

    package var captures: [ClientCapture]
}

package struct ScreenIngestResult: Codable, Equatable {
    package init(stored: Int, unchanged: Int, skipped: Int) {
        self.stored = stored
        self.unchanged = unchanged
        self.skipped = skipped
    }

    /// Captures that added something new.
    package var stored: Int
    /// Captures with nothing new since the window's last one.
    package var unchanged: Int
    /// Captures dropped: capture is paused or off for that app, or the capture had no text.
    package var skipped: Int
}

extension ScreenAPI {
    /// The most captures one call takes.
    package static let maxIngestCaptures = 50
    /// The most lines one capture may carry.
    package static let maxIngestLines = 5000

    /// Stores captures a client took on its own screen. The client redacts before it sends. Pause and the app deny lists apply as they do
    /// to a capture taken here.
    package func ingest(_ request: ScreenIngestRequest) async throws -> ScreenIngestResult {
        guard !request.captures.isEmpty else { throw APIError.invalid("captures is empty") }
        guard request.captures.count <= Self.maxIngestCaptures else {
            throw APIError.invalid("a call takes at most \(Self.maxIngestCaptures) captures")
        }
        for (index, capture) in request.captures.enumerated() {
            guard capture.redacted else { throw APIError.invalid("captures[\(index)] is not redacted: the client redacts before it sends") }
            guard !capture.app.isEmpty else { throw APIError.invalid("captures[\(index)].app is empty") }
            guard capture.lines.count <= Self.maxIngestLines else { throw APIError.invalid("captures[\(index)] has more than \(Self.maxIngestLines) lines") }
            guard CaptureTrigger(rawValue: capture.trigger) != nil else { throw APIError.invalid("captures[\(index)].trigger \"\(capture.trigger)\" is not a trigger") }
        }
        let control = control, captures = request.captures
        // A `CapabilityError` passes through unchanged, so the wire error keeps the capability and the platform.
        return try await Task.detached(priority: .userInitiated) { try control.ingest(captures) }.value
    }
}
