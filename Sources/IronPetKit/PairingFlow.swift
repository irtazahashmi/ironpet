import Foundation

/// What a finished pairing leaves on the phone.
public struct PairedDevice: Codable, Equatable, Sendable {
    public var endpoint: ServerEndpoint
    public var token: String
    public var deviceID: String

    public init(endpoint: ServerEndpoint, token: String, deviceID: String) {
        self.endpoint = endpoint; self.token = token; self.deviceID = deviceID
    }
}

/// Pairs with a Mac from a link: asks with the code, checks who answered, then polls until the user presses Allow or Deny on the Mac.
public struct PairingFlow: Sendable {
    public var link: PairingLink
    public var deviceName: String
    public var pollInterval: Duration

    public init(link: PairingLink, deviceName: String, pollInterval: Duration = .seconds(1)) {
        self.link = link; self.deviceName = deviceName; self.pollInterval = pollInterval
    }

    /// The certificate pin applies to `https` links. An `http` link is the Mac's loopback listener, which carries no `f`.
    public var endpoint: ServerEndpoint {
        ServerEndpoint(baseURL: link.baseURL, pin: link.baseURL.scheme?.lowercased() == "https" ? link.fingerprint : nil)
    }

    /// `onWaiting` runs once the Mac has the request and shows its Allow bubble.
    public func run(onWaiting: @Sendable () -> Void = {}) async throws -> PairedDevice {
        let client = IronPetClient(endpoint: endpoint)
        let accepted = try await client.pair(PairRequest(code: link.code, deviceName: deviceName))
        onWaiting()
        let deadline = ContinuousClock.now + .seconds(max(accepted.expiresIn, 1))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let poll = try await client.pollPairing(id: accepted.pairingID, secret: accepted.secret)
            switch poll.status {
            case .pending: try await Task.sleep(for: pollInterval)
            case .denied: throw ClientError.pairingDenied
            case .expired: throw ClientError.pairingExpired
            case .allowed:
                guard let token = poll.token, let id = poll.deviceID else { throw ClientError.invalidResponse }
                return PairedDevice(endpoint: endpoint, token: token, deviceID: id)
            }
        }
        throw ClientError.pairingExpired
    }
}
