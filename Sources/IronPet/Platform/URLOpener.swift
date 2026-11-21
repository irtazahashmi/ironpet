import Foundation

/// Opens an address or a file in whatever app this machine uses for it. The Mac adapter is `MacURLOpener`. A bubble's "Open"
/// button carries the `open-url` action id, and the client that shows the bubble performs it through this protocol.
protocol URLOpener: Sendable {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    var isSupported: Bool { get }
    /// Throws `CapabilityError.unsupported` where nothing can open it.
    func open(_ url: URL) throws
}

extension URLOpener {
    var isSupported: Bool { true }
}

/// Opens nothing.
struct UnsupportedURLOpener: URLOpener {
    var platform = PlatformName.current
    var isSupported: Bool { false }

    init() {}

    func open(_ url: URL) throws { throw CapabilityError.unsupported(capability: "URLOpener", platform: platform) }
}

extension Bubble.Action {
    /// The id of a button that opens the bubble's address.
    static let openURLID = "open-url"
}
