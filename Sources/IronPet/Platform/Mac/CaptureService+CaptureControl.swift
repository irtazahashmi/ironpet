import Foundation
import IronPetCore

/// The Mac adapter for `CaptureControl` is the capture service. Each member does what `ScreenAPI` did itself before, in the same order.
extension CaptureService: CaptureControl {
    var isSupported: Bool { true }

    func refreshModel() { refreshModel(captured: false) }

    func pause(for seconds: TimeInterval) throws {
        privacy.pause(for: seconds)
        refreshModel()
    }

    func pauseUntilTomorrow() throws {
        privacy.pauseUntilTomorrow()
        refreshModel()
    }

    func resume() throws {
        privacy.resume()
        refreshModel()
    }

    func clearCaptures() throws {
        store.clear()
        refreshModel()
    }

    func recentCaptures(limit: Int) -> [StoredCapture] { store.recent(limit: limit) }

    func searchCaptures(_ query: String, app: String?, since: Date?, until: Date?, limit: Int) -> [CaptureHit] {
        store.search(query, app: app, since: since, until: until, limit: limit)
    }

    func captureText(_ id: Int64) -> String? { store.capture(id: id)?.text }

    func seenApps() -> [(bundleId: String, name: String, captures: Int)] { store.seenApps() }

    func callTool(_ name: String, _ args: [String: Any]) -> Result<Any, ScreenMCP.Failure> {
        ScreenMCP.call(name, args, store: store)
    }

    /// Captures another client took and redacted. They pass the same privacy gate as a capture taken here, then the store, which
    /// redacts again and keeps the tree and what is new.
    func ingest(_ captures: [ClientCapture]) throws -> ScreenIngestResult {
        var result = ScreenIngestResult(stored: 0, unchanged: 0, skipped: 0)
        for capture in captures {
            let app = CaptureApp(bundleId: capture.app, name: capture.appName)
            let at = capture.at ?? Date()
            guard privacy.checkApp(app, now: at) == nil, let trigger = CaptureTrigger(rawValue: capture.trigger) else { result.skipped += 1; continue }
            switch try store.ingest(app: app, title: capture.title, url: capture.url, trigger: trigger, lines: capture.lines,
                                    inputLines: capture.inputLines ?? [], now: at) {
            case .stored: result.stored += 1
            case .unchanged: result.unchanged += 1
            case .empty: result.skipped += 1
            }
        }
        refreshModel()
        return result
    }
}
