import Foundation

/// The screen-capture controls `ScreenAPI` needs: the status the Screen section shows, pausing, and reading or clearing what was
/// stored. The Mac adapter is `CaptureService`, which reads windows through the Accessibility API.
package protocol CaptureControl: AnyObject, Sendable {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    var isSupported: Bool { get }
    /// Whether capture runs, what macOS allows it, whether it is paused, how many captures are stored.
    @MainActor var model: CaptureStatusModel { get }
    /// Reads the state again, for example after the user changed a permission.
    func refreshModel()

    /// Pauses capture for `seconds`. Throws `CapabilityError.unsupported` where nothing captures.
    func pause(for seconds: TimeInterval) throws
    func pauseUntilTomorrow() throws
    func resume() throws
    /// Deletes every stored capture.
    func clearCaptures() throws

    func recentCaptures(limit: Int) -> [StoredCapture]
    func searchCaptures(_ query: String, app: String?, since: Date?, until: Date?, limit: Int) -> [CaptureHit]
    /// The text stored for one capture. Nil when it was deleted.
    func captureText(_ id: Int64) -> String?
    func seenApps() -> [(bundleId: String, name: String, captures: Int)]
    /// The MCP tools `screen_search` and `screen_window`, which read loose JSON arguments.
    func callTool(_ name: String, _ args: [String: Any]) -> Result<Any, ScreenMCP.Failure>
}

extension CaptureControl {
    package var isSupported: Bool { true }
}

/// Captures nothing and stores nothing.
package final class UnsupportedCaptureControl: CaptureControl, @unchecked Sendable { // `model` is touched only on the main actor.
    package var platform = PlatformName.current
    package var isSupported: Bool { false }
    @MainActor package let model = CaptureStatusModel()

    package init() {}

    private var error: CapabilityError { .unsupported(capability: "CaptureControl", platform: platform) }

    package func refreshModel() {}
    package func pause(for seconds: TimeInterval) throws { throw error }
    package func pauseUntilTomorrow() throws { throw error }
    package func resume() throws { throw error }
    package func clearCaptures() throws { throw error }
    package func recentCaptures(limit: Int) -> [StoredCapture] { [] }
    package func searchCaptures(_ query: String, app: String?, since: Date?, until: Date?, limit: Int) -> [CaptureHit] { [] }
    package func captureText(_ id: Int64) -> String? { nil }
    package func seenApps() -> [(bundleId: String, name: String, captures: Int)] { [] }
    package func callTool(_ name: String, _ args: [String: Any]) -> Result<Any, ScreenMCP.Failure> {
        .failure(ScreenMCP.Failure(message: error.localizedDescription))
    }
}
