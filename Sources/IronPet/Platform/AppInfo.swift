import Foundation

/// What the platform can say about the apps around an agent.
protocol AppInfo: Sendable {
    var isSupported: Bool { get }
    /// Bundle id of the first ancestor of `pid` (the process itself included) that is a packaged app, or nil.
    func owningBundleID(pid: Int32) throws -> String?
    /// The display name of the app with `bundleID`, or nil when it is not installed.
    func displayName(bundleID: String) throws -> String?
}

extension AppInfo {
    var isSupported: Bool { true }
}

struct UnsupportedAppInfo: AppInfo {
    var platform = PlatformName.current
    var isSupported: Bool { false }
    private var error: CapabilityError { .unsupported(capability: "AppInfo", platform: platform) }
    func owningBundleID(pid: Int32) throws -> String? { throw error }
    func displayName(bundleID: String) throws -> String? { throw error }
}
