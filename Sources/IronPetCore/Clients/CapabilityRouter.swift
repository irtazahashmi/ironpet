import Foundation
import IronPetKit

/// Sends the server's own requests to clients: a screenshot now, a desktop action. A request goes only to a client that advertises
/// its capability. With none, the call fails with `CapabilityError.unsupported`, so a caller can tell "nothing can do this" from a
/// failure.
@MainActor
package struct CapabilityRouter {
    /// What happened to a request.
    package enum Delivery: Equatable {
        /// `client` did it and answered with `reply`.
        case delivered(client: ClientSession, reply: RemoteJSON)
        /// Several clients could do it and nothing says which. The caller asks the user, then sends again with a `ChatOrigin` whose
        /// `device` is the one they pick.
        case ask(candidates: [ClientSession])
    }

    private let registry: ClientRegistry

    package init(registry: ClientRegistry) { self.registry = registry }

    /// Throws `CapabilityError.unsupported` when no connected client advertises `request.capability`, and
    /// `APIError.unavailable` when the chosen client cannot take requests right now.
    package func send(_ request: ClientRequest, origin: ChatOrigin? = nil) async throws -> Delivery {
        guard !registry.clients(advertising: request.capability).isEmpty else {
            throw CapabilityError.unsupported(capability: request.capability.rawValue, platform: platform(for: origin))
        }
        switch registry.resolve(request.capability, origin: origin) {
        case .ask(let candidates):
            // A client with the capability that is not a desktop leaves nobody for the user to pick, so it is unsupported, not a question.
            guard !candidates.isEmpty else {
                throw CapabilityError.unsupported(capability: request.capability.rawValue, platform: platform(for: origin))
            }
            return .ask(candidates: candidates)
        case .client(let client):
            guard let handler = registry.handler(for: client.id) else {
                throw APIError.unavailable("\(client.name) cannot take requests right now")
            }
            return .delivered(client: client, reply: try await handler(request))
        }
    }

    /// The platform to name in the error: the one the person is on, else the one this host runs on.
    private func platform(for origin: ChatOrigin?) -> String {
        if let device = origin?.device, let session = registry.sessions(forDevice: device).first { return session.kind.platformName }
        return registry.local?.kind.platformName ?? PlatformName.current
    }
}
