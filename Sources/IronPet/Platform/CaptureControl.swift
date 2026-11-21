import Foundation

/// The screen-capture controls `ScreenAPI` needs: the status the Screen section shows, pausing, and reading or clearing what was
/// stored. The Mac adapter is `CaptureService`, which reads windows through the Accessibility API.
protocol CaptureControl: AnyObject, Sendable {
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
    var isSupported: Bool { true }
}

/// Captures nothing and stores nothing.
final class UnsupportedCaptureControl: CaptureControl, @unchecked Sendable { // `model` is touched only on the main actor.
    var platform = PlatformName.current
    var isSupported: Bool { false }
    @MainActor let model = CaptureStatusModel()

    init() {}

    private var error: CapabilityError { .unsupported(capability: "CaptureControl", platform: platform) }

    func refreshModel() {}
    func pause(for seconds: TimeInterval) throws { throw error }
    func pauseUntilTomorrow() throws { throw error }
    func resume() throws { throw error }
    func clearCaptures() throws { throw error }
    func recentCaptures(limit: Int) -> [StoredCapture] { [] }
    func searchCaptures(_ query: String, app: String?, since: Date?, until: Date?, limit: Int) -> [CaptureHit] { [] }
    func captureText(_ id: Int64) -> String? { nil }
    func seenApps() -> [(bundleId: String, name: String, captures: Int)] { [] }
    func callTool(_ name: String, _ args: [String: Any]) -> Result<Any, ScreenMCP.Failure> {
        .failure(ScreenMCP.Failure(message: error.localizedDescription))
    }
}
