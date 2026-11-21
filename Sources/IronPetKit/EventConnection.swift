#if canImport(Darwin)
import Foundation

/// What the event socket tells its reader.
public enum EventSignal: Equatable, Sendable {
    /// The socket is open (first time or after a drop). The reader reloads what it shows, since events may have passed before it opened.
    case connected
    case event(RemoteEvent)
    /// The Mac no longer holds the events after the last `seq`. The reader reads everything again.
    case resync
    /// The upgrade answered 401: the token is gone.
    case unauthorized
}

/// `GET /v1/events` as a stream. It reconnects with back-off and passes the last `seq` it saw as `since`.
public final class EventConnection: @unchecked Sendable {
    public struct Backoff: Sendable {
        public var initial: Duration
        public var maximum: Duration
        public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) { self.initial = initial; self.maximum = maximum }
        func delay(attempt: Int) -> Duration {
            var delay = initial
            for _ in 0..<min(attempt, 12) { delay = delay * 2; if delay >= maximum { return maximum } }
            return min(delay, maximum)
        }
    }

    private let client: IronPetClient
    private let backoff: Backoff
    private let lock = NSLock()
    private var last: Int?

    public init(client: IronPetClient, backoff: Backoff = Backoff()) {
        self.client = client
        self.backoff = backoff
    }

    /// The highest `seq` seen so far.
    public var lastSeq: Int? { lock.lock(); defer { lock.unlock() }; return last }

    private func record(_ seq: Int) { lock.lock(); last = max(last ?? 0, seq); lock.unlock() }
    private func reset(to seq: Int) { lock.lock(); last = seq; lock.unlock() }

    /// Ends when the consumer stops iterating or the token is refused.
    public func signals() -> AsyncStream<EventSignal> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func socketURL() -> URLRequest {
        var items: [URLQueryItem] = []
        if let seq = lastSeq { items.append(URLQueryItem(name: "since", value: String(seq))) }
        var request = client.request("GET", APIPath.events, query: items)
        if var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            parts.scheme = parts.scheme?.lowercased() == "https" ? "wss" : "ws"
            request.url = parts.url
        }
        return request
    }

    private func run(_ continuation: AsyncStream<EventSignal>.Continuation) async {
        let decoder = WireJSON.makeDecoder()
        var attempt = 0
        while !Task.isCancelled {
            let socket = client.session.webSocketTask(with: socketURL())
            socket.resume()
            do {
                while true {
                    let message = try await withTaskCancellationHandler {
                        try await socket.receive()
                    } onCancel: {
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard let event = try? decoder.decode(RemoteEvent.self, from: data) else { continue }
                    attempt = 0
                    switch event.kind {
                    case RemoteEvent.hello:
                        if lastSeq == nil { reset(to: event.seq) }
                        continuation.yield(.connected)
                    case RemoteEvent.resync:
                        reset(to: event.seq)
                        continuation.yield(.resync)
                    default:
                        record(event.seq)
                        continuation.yield(.event(event))
                    }
                }
            } catch {
                if (socket.response as? HTTPURLResponse)?.statusCode == 401 {
                    continuation.yield(.unauthorized)
                    continuation.finish()
                    return
                }
            }
            socket.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { break }
            try? await Task.sleep(for: backoff.delay(attempt: attempt))
            attempt += 1
        }
        continuation.finish()
    }
}
#endif
