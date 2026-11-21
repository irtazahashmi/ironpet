import Foundation

/// One thing the Mac sent on the voice socket.
public enum VoiceInbound: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// The voice socket as the phone's voice code sees it. A test replaces it with a recording fake.
public protocol VoiceChannel: AnyObject, Sendable {
    func send(text: String) async throws
    func send(binary: Data) async throws
    /// What the Mac sends, until the socket closes. The stream throws when the socket fails.
    func incoming() -> AsyncThrowingStream<VoiceInbound, Error>
    func close()
}

/// `GET /v1/voice` as a WebSocket over the client's own session, so the certificate pin applies.
public final class URLSessionVoiceChannel: VoiceChannel, @unchecked Sendable {
    /// A reply's audio is one WAV per chunk, which is larger than the 1 MiB default.
    static let maximumMessageSize = 8 << 20

    private let task: URLSessionWebSocketTask

    init(client: IronPetClient) {
        var request = client.request("GET", APIPath.voice)
        if var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            parts.scheme = parts.scheme?.lowercased() == "https" ? "wss" : "ws"
            request.url = parts.url
        }
        task = client.session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()
    }

    public func send(text: String) async throws { try await task.send(.string(text)) }
    public func send(binary: Data) async throws { try await task.send(.data(binary)) }

    public func incoming() -> AsyncThrowingStream<VoiceInbound, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    while true {
                        switch try await task.receive() {
                        case .string(let text): continuation.yield(.text(text))
                        case .data(let data): continuation.yield(.binary(data))
                        @unknown default: continue
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    public func close() { task.cancel(with: .goingAway, reason: nil) }
}

extension IronPetClient {
    /// Opens the voice socket. It connects at once and fails on first use when the Mac refuses.
    public func openVoiceChannel() -> any VoiceChannel { URLSessionVoiceChannel(client: self) }
}
