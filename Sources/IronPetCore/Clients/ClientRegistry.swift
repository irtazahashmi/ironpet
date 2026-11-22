import Foundation
import IronPetKit

/// A server-initiated call to one client, such as "take a screenshot". Plain data, so it can go over any transport.
package struct ClientRequest: Codable, Equatable, Sendable {
    package init(capability: ClientCapability, method: String, params: RemoteJSON? = nil) {
        self.capability = capability
        self.method = method
        self.params = params
    }

    /// What the client must advertise to get this request.
    package var capability: ClientCapability
    /// The client's method, such as `screen.capture`.
    package var method: String
    package var params: RemoteJSON?
}

/// How the registry reaches a client. The in-process Mac client answers with a closure. A remote client answers over its socket.
package typealias ClientHandler = @MainActor (ClientRequest) async throws -> RemoteJSON

/// Where a capability request should go, as `ClientRegistry.resolve` decides.
package enum ClientTarget: Equatable, Sendable {
    /// Send it to this client.
    case client(ClientSession)
    /// No single client is the right one: nothing is connected that can do it, or two are equally recent. Ask the user which one
    /// they mean. The registry never picks between equals.
    case ask(candidates: [ClientSession])
}

/// Every client connected to the core right now: the app's own window, and each paired device that has its event socket open.
/// A session starts when a client connects and ends when it disconnects. Nothing is stored.
@MainActor
package final class ClientRegistry {
    /// The device id of the app that hosts the core.
    package static let localDeviceID = "local"

    private let now: () -> Date
    private let newID: () -> String
    private var handlers: [String: ClientHandler] = [:]
    /// Oldest connection first.
    package private(set) var sessions: [ClientSession] = []

    package init(now: @escaping () -> Date = Date.init, newID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.now = now
        self.newID = newID
    }

    // MARK: Sessions

    /// Starts a session for a client that just connected.
    @discardableResult
    package func connect(
        deviceID: String, name: String, kind: ClientKind, capabilities: [ClientCapability] = [], connection: ClientConnection,
        client: ClientInfo? = nil, handler: ClientHandler? = nil
    ) -> ClientSession {
        let session = ClientSession(id: newID(), deviceID: deviceID, name: name, kind: kind, capabilities: capabilities,
                                    connectedAt: now(), connection: connection, client: client)
        sessions.append(session)
        handlers[session.id] = handler
        return session
    }

    /// Ends a session. Returns it, or nil when it was already gone.
    @discardableResult
    package func disconnect(_ id: String) -> ClientSession? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        handlers[id] = nil
        return sessions.remove(at: index)
    }

    package func session(_ id: String) -> ClientSession? { sessions.first { $0.id == id } }

    package func sessions(forDevice deviceID: String) -> [ClientSession] { sessions.filter { $0.deviceID == deviceID } }

    /// Changes one session. A session that is gone stays gone.
    @discardableResult
    package func update(_ id: String, _ change: (inout ClientSession) -> Void) -> ClientSession? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        change(&sessions[index])
        // Sorted again here, so a change cannot leave a set that encodes differently from an equal one.
        sessions[index].capabilities = Array(Set(sessions[index].capabilities)).sorted()
        return sessions[index]
    }

    /// Records that the person used this client's keyboard or mouse at `date`. An older date never replaces a newer one.
    package func recordInput(_ id: String, at date: Date) {
        update(id) { session in
            if let last = session.lastInputAt, last >= date { return }
            session.lastInputAt = date
        }
    }

    // MARK: The local client

    /// The in-process client: the app that hosts the core. Nil until `registerLocal` runs.
    package var local: ClientSession? { sessions.first { $0.connection == .inProcess } }

    /// Registers the app as the local client, or updates it when it is registered already, so a later adapter (screen capture and
    /// desktop control start after launch) changes the capabilities without a second session.
    @discardableResult
    package func registerLocal(name: String, kind: ClientKind, capabilities: [ClientCapability], handler: ClientHandler? = nil) -> ClientSession {
        if let existing = local {
            handlers[existing.id] = handler
            return update(existing.id) {
                $0.name = name
                $0.kind = kind
                $0.capabilities = capabilities
            } ?? existing
        }
        return connect(deviceID: Self.localDeviceID, name: name, kind: kind, capabilities: capabilities, connection: .inProcess, handler: handler)
    }

    /// Registers the app on a platform: its capabilities are the platform's real adapters, plus `extra`.
    @discardableResult
    package func registerLocal(name: String, kind: ClientKind, platform: Platform, extra: [ClientCapability] = [],
                               handler: ClientHandler? = nil) -> ClientSession {
        registerLocal(name: name, kind: kind, capabilities: platform.clientCapabilities(extra: extra), handler: handler)
    }

    // MARK: Routing

    package func handler(for id: String) -> ClientHandler? { handlers[id] }

    /// The sessions that advertise `capability`, most recently active first. Sessions equally recent keep connection order.
    package func clients(advertising capability: ClientCapability) -> [ClientSession] {
        sessions.filter { $0.advertises(capability) }.enumerated()
            .sorted { ($0.element.lastActiveAt, $1.offset) > ($1.element.lastActiveAt, $0.offset) }.map(\.element)
    }

    /// Decides which client a request that needs `capability` goes to, for a chat turn that came from `origin`:
    /// 1. A client of the origin device that advertises it. A phone asking for "my screen" has none, so it falls through.
    /// 2. The desktop client that advertises it and was active most recently.
    /// 3. Otherwise `.ask`, with the desktop clients that could do it. Two equally recent ones also ask: no guessing.
    package func resolve(_ capability: ClientCapability, origin: ChatOrigin? = nil) -> ClientTarget {
        if let device = origin?.device, let own = clients(advertising: capability).first(where: { $0.deviceID == device }) {
            return .client(own)
        }
        let desktops = clients(advertising: capability).filter { $0.kind.isDesktop }
        guard let newest = desktops.first else { return .ask(candidates: []) }
        let tied = desktops.filter { $0.lastActiveAt == newest.lastActiveAt }
        return tied.count > 1 ? .ask(candidates: tied) : .client(newest)
    }

    /// "My screen": where the person means when they say it in a chat turn from `origin`.
    package func resolveScreen(origin: ChatOrigin? = nil) -> ClientTarget { resolve(.screen, origin: origin) }
}
