import Foundation

/// `session.hello`: the first request on a connection. It says which contract version the client speaks and who it is, and it
/// answers with the session the host opened, what the host serves, and where the event stream stands.
package struct HelloRequest: Codable, Equatable {
    package init(protocolVersion: Int, client: ClientInfo, lastSeq: Int? = nil) {
        self.protocolVersion = protocolVersion
        self.client = client
        self.lastSeq = lastSeq
    }

    /// The contract version the client speaks. `"protocol"` on the wire.
    package var protocolVersion: Int
    package var client: ClientInfo
    /// The last event `seq` the client saw, so the host can say whether it missed any.
    package var lastSeq: Int?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case client, lastSeq
    }
}

package struct HelloResult: Codable, Equatable {
    package init(protocolVersion: Int, server: ClientInfo, session: String, capabilities: [String], seq: Int, gap: Bool) {
        self.protocolVersion = protocolVersion
        self.server = server
        self.session = session
        self.capabilities = capabilities
        self.seq = seq
        self.gap = gap
    }

    package var protocolVersion: Int
    package var server: ClientInfo
    /// The id of this connection's `ClientSession`.
    package var session: String
    /// The facades this host serves, not what the client can do for the host.
    package var capabilities: [String]
    /// The newest event number.
    package var seq: Int
    /// True when the host no longer held every event after `lastSeq`. The client reads each area again.
    package var gap: Bool

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case server, session, capabilities, seq, gap
    }
}

/// What a transport knows about the connection a request arrived on. The remote server makes one when a device's event socket
/// opens, and the dispatcher hands it to `session.hello`.
@MainActor
package final class RPCConnection {
    package init(deviceID: String, name: String, kind: ClientKind, connection: ClientConnection, sessionID: String? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.connection = connection
        self.sessionID = sessionID
    }

    package let deviceID: String
    package let name: String
    package let kind: ClientKind
    package let connection: ClientConnection
    /// The session this connection opened, once it has one.
    package var sessionID: String?
}

/// The handshake, and the registry of clients behind it.
@MainActor
package final class SessionAPI {
    /// The contract versions this host speaks. `docs/protocol.md` is version 1.
    package static let supportedProtocols = [1]
    package static let serverName = "IronPetCore"

    package let clients: ClientRegistry
    private let events: APIEventBus
    private let facades: () -> [String]
    package var serverVersion: String

    package init(clients: ClientRegistry, events: APIEventBus, serverVersion: String = "0", facades: @escaping () -> [String]) {
        self.clients = clients
        self.events = events
        self.serverVersion = serverVersion
        self.facades = facades
    }

    /// The sessions connected now, oldest first.
    package func sessions() -> [ClientSession] { clients.sessions }

    /// Answers a client's first request. The connection already has a session when its transport opened one (a device's event
    /// socket does), and hello names the program in it. Otherwise hello opens the session.
    package func hello(_ request: HelloRequest, connection: RPCConnection) throws -> HelloResult {
        guard Self.supportedProtocols.contains(request.protocolVersion) else {
            throw APIError.invalid("protocol \(request.protocolVersion) is not supported, this host speaks \(Self.supportedProtocols)")
        }
        let client = ClientInfo(name: String(request.client.name.prefix(80)), version: String(request.client.version.prefix(40)))
        let session: ClientSession
        if let id = connection.sessionID, let known = clients.update(id, { $0.client = client }) {
            session = known
        } else {
            session = clients.connect(deviceID: connection.deviceID, name: connection.name, kind: connection.kind, connection: connection.connection,
                                      client: client)
            connection.sessionID = session.id
        }
        let gap = request.lastSeq.map { events.replay(after: $0).gap } ?? false
        return HelloResult(protocolVersion: Self.supportedProtocols.last ?? 1, server: ClientInfo(name: Self.serverName, version: serverVersion),
                           session: session.id, capabilities: facades(), seq: events.lastSeq, gap: gap)
    }
}
