import Foundation

/// What kind of machine or program a client is. The kind says how it connects and what it can usually do, not what it advertises:
/// `ClientSession.capabilities` is the list the router trusts.
package enum ClientKind: String, Codable, CaseIterable, Sendable {
    case mac
    case ios
    case cli
    case windows

    /// A client with a screen and a keyboard of its own. "My screen" and desktop actions go to one of these.
    package var isDesktop: Bool { self == .mac || self == .windows }

    /// The name `CapabilityError.unsupported` reports for a client of this kind.
    package var platformName: String {
        switch self {
        case .mac: return "macOS"
        case .ios: return "iOS"
        case .cli: return "the command line"
        case .windows: return "Windows"
        }
    }
}

/// One thing a client can do for the server when the server asks. A client advertises the ones it has, and `CapabilityRouter`
/// sends a request only to a client that lists it. The string is the wire form.
package struct ClientCapability: RawRepresentable, Codable, Hashable, Comparable, ExpressibleByStringLiteral, Sendable {
    package init(rawValue: String) { self.rawValue = rawValue }
    package init(stringLiteral value: String) { rawValue = value }

    package let rawValue: String

    package static func < (lhs: ClientCapability, rhs: ClientCapability) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Reads the client's screen: a screenshot, or the text of its windows. Backed by the `CaptureControl` adapter.
    package static let screen: ClientCapability = "screen"
    /// Presses, types and opens things in other apps on the client. The Mac has it while its desktop tools exist.
    package static let desktop: ClientCapability = "desktop"
    /// Reports keyboard and mouse input, so `lastInputAt` moves. Backed by the `PresenceSource` adapter.
    package static let presence: ClientCapability = "presence"
}

/// How a session reaches the server.
package enum ClientConnection: String, Codable, Sendable {
    /// The app that hosts the core. No socket: the session lives as long as the app.
    case inProcess
    /// A device on the remote server. The session ends when the socket closes.
    case remote
}

/// Who a client says it is in `session.hello`, and who the server says it is in the answer.
package struct ClientInfo: Codable, Equatable, Sendable {
    package init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    package var name: String
    package var version: String
}

/// One connected client. Plain data: the way to reach it (a socket, a closure) is kept by `ClientRegistry`, not here, so the
/// value can be sent to any client as it is.
package struct ClientSession: Codable, Equatable, Identifiable, Sendable {
    package init(
        id: String,
        deviceID: String,
        name: String,
        kind: ClientKind,
        capabilities: [ClientCapability] = [],
        lastInputAt: Date? = nil,
        connectedAt: Date,
        subscriptions: [String] = [],
        connection: ClientConnection,
        client: ClientInfo? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.capabilities = Array(Set(capabilities)).sorted()
        self.lastInputAt = lastInputAt
        self.connectedAt = connectedAt
        self.subscriptions = subscriptions
        self.connection = connection
        self.client = client
    }

    /// The session's own id, new for each connection. A device that connects twice has two sessions.
    package var id: String
    /// The paired device's id. The in-process client uses `ClientRegistry.localDeviceID`.
    package var deviceID: String
    package var name: String
    package var kind: ClientKind
    /// Sorted, so the same set always encodes the same way.
    package var capabilities: [ClientCapability]
    /// When the person last used this client's keyboard or mouse, as the client reported it. Nil when it does not say.
    package var lastInputAt: Date?
    package var connectedAt: Date
    /// Event names the client wants. Empty means every event.
    package var subscriptions: [String]
    package var connection: ClientConnection
    /// The program and version, once the client has said hello.
    package var client: ClientInfo?

    package func advertises(_ capability: ClientCapability) -> Bool { capabilities.contains(capability) }

    /// When the person was last at this client: its last input, else when it connected.
    package var lastActiveAt: Date { lastInputAt ?? connectedAt }
}
