import Foundation

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
}
