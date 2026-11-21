import Foundation

/// What the platform can say about the apps around an agent.
package protocol AppInfo: Sendable {
    var isSupported: Bool { get }
    /// Bundle id of the first ancestor of `pid` (the process itself included) that is a packaged app, or nil.
    func owningBundleID(pid: Int32) throws -> String?
    /// The display name of the app with `bundleID`, or nil when it is not installed.
    func displayName(bundleID: String) throws -> String?
}

extension AppInfo {
    package var isSupported: Bool { true }
}

package struct UnsupportedAppInfo: AppInfo {
    package init() {}

    package var platform = PlatformName.current
    package var isSupported: Bool { false }
    private var error: CapabilityError { .unsupported(capability: "AppInfo", platform: platform) }
    package func owningBundleID(pid: Int32) throws -> String? { throw error }
    package func displayName(bundleID: String) throws -> String? { throw error }
}
