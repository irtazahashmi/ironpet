import Foundation
import IronPetKit

/// The screen routes, as calls on `IronPetAPI.screen`. Every read goes through the `screen_*` agent tools, so the text a phone gets is
/// what an agent gets: redacted when it was stored and filtered again on read. Nothing here reads a store directly, bypasses
/// `ScreenMCP`, or logs screen text. The caps of the tools stay (30 change lines per window, 50 search results).
///
/// The server checks the `screen` scope and the hourly limit before any of these run.
@MainActor
package struct RemoteScreen {
    package init(screen: ScreenAPI) {
        self.screen = screen
    }

    package let screen: ScreenAPI

    package static let maxSearchResults = 50

    /// Reads the capture state again first. The model updates on the main queue, so this waits one turn of it.
    package func status() async -> [String: Any] {
        screen.refreshStatus()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
        let model = screen.status
        return RemoteWire.object(RemoteScreenStatus(running: model.running, accessibility: model.accessibility, screenRecording: model.screenRecording,
                                                    paused: model.paused, pausedUntil: model.pausedUntil, captureCount: model.captureCount,
                                                    lastCapture: model.lastCapture))
    }

    /// `since` (default today), `until`, `app` and `window`, as `screen_window` without an id.
    package func changes(query: [String: [String]]) throws -> [String: Any] {
        var args: [String: Any] = ["since": query["since"]?.first ?? "today"]
        for key in ["until", "app", "window"] { if let value = query[key]?.first, !value.isEmpty { args[key] = value } }
        return try tool("screen_window", args)
    }

    /// `screen_window` with an id, and optionally `root`, `role`, `text` and `depth`.
    package func capture(_ id: String, query: [String: [String]]) throws -> [String: Any] {
        guard let number = Int(id) else { throw RemoteFailure.invalid("the capture id must be a number") }
        var args: [String: Any] = ["id": number]
        for key in ["root", "role", "text"] { if let value = query[key]?.first, !value.isEmpty { args[key] = value } }
        if let depth = query["depth"]?.first {
            guard let value = Int(depth), (1...20).contains(value) else { throw RemoteFailure.invalid("depth must be a number from 1 to 20") }
            args["depth"] = value
        }
        return try tool("screen_window", args)
    }

    /// `q`, `app`, `since`, `until` and `limit` (1 to 50, default 20), as `screen_search`.
    package func search(query: [String: [String]]) throws -> [String: Any] {
        guard let q = query["q"]?.first, !q.trimmingCharacters(in: .whitespaces).isEmpty else { throw RemoteFailure.invalid("q is required") }
        var args: [String: Any] = ["query": q]
        for key in ["app", "since", "until"] { if let value = query[key]?.first, !value.isEmpty { args[key] = value } }
        if let limit = query["limit"]?.first {
            guard let value = Int(limit), (1...Self.maxSearchResults).contains(value) else { throw RemoteFailure.invalid("limit must be a number from 1 to \(Self.maxSearchResults)") }
            args["limit"] = value
        }
        return try tool("screen_search", args)
    }

    /// `{"minutes": n}` (1 to 1440) or `{"until": "tomorrow"}`, like the pause buttons of Settings → Screen. There is no resume here.
    package func pause(_ body: [String: Any]) async throws -> [String: Any] {
        if (body["until"] as? String) == "tomorrow" {
            screen.pauseUntilTomorrow()
        } else if let minutes = (body["minutes"] as? NSNumber)?.intValue {
            guard (1...1440).contains(minutes) else { throw RemoteFailure.invalid("minutes must be a number from 1 to 1440") }
            try screen.pause(for: TimeInterval(minutes * 60))
        } else {
            throw RemoteFailure.invalid("give minutes, or until: tomorrow")
        }
        return await status()
    }

    /// Runs a tool of `ScreenMCP`. Its failure text names a time or a capture id, never screen text.
    private func tool(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        switch screen.callTool(name, args) {
        case .success(let value):
            guard let object = value as? [String: Any] else { throw RemoteFailure(status: 500, code: "failed", message: "internal error") }
            return object
        case .failure(let failure):
            let missing = failure.message.hasPrefix("no capture") || failure.message.hasPrefix("no element") || failure.message.contains("is no longer stored")
            throw RemoteFailure(status: missing ? 404 : 400, code: missing ? "not_found" : "invalid", message: failure.message)
        }
    }
}
