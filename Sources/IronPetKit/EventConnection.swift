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

/// The Mac's answer to a message sent over the event socket.
public struct ChatAck: Equatable, Sendable {
    public var clientID: String
    public var outcome: String
    /// Nil when the message waits in the Mac's queue and has no item yet.
    public var itemID: String?
    public var seq: Int

    public init(clientID: String, outcome: String, itemID: String?, seq: Int) {
        self.clientID = clientID
        self.outcome = outcome
        self.itemID = itemID
        self.seq = seq
    }
}

/// Why a message could not go over the event socket.
public enum SocketSendError: Error, Equatable, Sendable {
    /// The socket is not open, or the Mac did not announce `chat.send`. Nothing was written, so the caller sends over HTTPS.
    case unavailable
    /// The socket closed after the frame was written. The Mac may have taken the message, so the caller resends with the same client id.
    case closed
    /// The Mac refused the message.
    case refused(code: String, message: String)
}

/// Anything that can send a chat message over the event socket. `EventConnection` is the real one.
public protocol ChatSocket: Sendable {
    /// True while the socket is open and the Mac announced `chat.send` in its hello frame.
    var canSendChat: Bool { get }
    func sendChat(clientID: String, text: String, reply: RemoteReplyRef?) async throws -> ChatAck
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
    /// The open socket, and whether its hello announced `chat.send`.
    private var open: URLSessionWebSocketTask?
    private var chatSendAnnounced = false
    private var waiting: [String: CheckedContinuation<ChatAck, Error>] = [:]

    public init(client: IronPetClient, backoff: Backoff = Backoff()) {
        self.client = client
        self.backoff = backoff
    }

    /// The highest `seq` seen so far.
    public var lastSeq: Int? { lock.lock(); defer { lock.unlock() }; return last }

    public var canSendChat: Bool { lock.lock(); defer { lock.unlock() }; return open != nil && chatSendAnnounced }

    /// Writes a `chat.send` frame and waits for the Mac's `chat.ack`. The caller bounds the wait, and a cancel stops it. Throws
    /// `unavailable` before writing anything when the socket cannot take the frame.
    public func sendChat(clientID: String, text: String, reply: RemoteReplyRef?) async throws -> ChatAck {
        var frame: [String: Any] = ["kind": "chat.send", "client_id": clientID, "text": text]
        if let reply {
            var quote: [String: Any] = ["item_id": reply.itemID]
            if let selection = reply.selectionText { quote["selection_text"] = selection }
            frame["reply"] = quote
        }
        guard let data = try? JSONSerialization.data(withJSONObject: frame), let line = String(data: data, encoding: .utf8) else { throw SocketSendError.unavailable }
        lock.lock()
        let socket = chatSendAnnounced ? open : nil
        lock.unlock()
        guard let socket else { throw SocketSendError.unavailable }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChatAck, Error>) in
                lock.lock()
                // A resend with the same id replaces the wait. The older call hears the same ack from the Mac either way.
                let replaced = waiting.updateValue(continuation, forKey: clientID)
                lock.unlock()
                replaced?.resume(throwing: CancellationError())
                // A cancel that arrived before the wait was registered found nothing to stop. Stop it here, before the frame leaves.
                if Task.isCancelled {
                    finish(clientID, .failure(CancellationError()))
                    return
                }
                socket.send(.string(line)) { [weak self] error in
                    if error != nil { self?.finish(clientID, .failure(SocketSendError.closed)) }
                }
            }
        } onCancel: {
            self.finish(clientID, .failure(CancellationError()))
        }
    }

    private func finish(_ clientID: String, _ result: Result<ChatAck, Error>) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: clientID)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func opened(_ socket: URLSessionWebSocketTask) { lock.lock(); open = socket; lock.unlock() }

    private func closed(_ socket: URLSessionWebSocketTask) {
        lock.lock()
        if open === socket { open = nil; chatSendAnnounced = false }
        let all = waiting
        waiting = [:]
        lock.unlock()
        for continuation in all.values { continuation.resume(throwing: SocketSendError.closed) }
    }

    private func announce(_ capabilities: [String]) { lock.lock(); chatSendAnnounced = capabilities.contains("chat.send"); lock.unlock() }

    /// `chat.ack` and `chat.nack` answer a send. They are not events, so they never reach the signal stream.
    private func answer(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = object["kind"] as? String, kind == "chat.ack" || kind == "chat.nack", let id = object["client_id"] as? String else { return false }
        if kind == "chat.ack" {
            finish(id, .success(ChatAck(clientID: id, outcome: object["outcome"] as? String ?? "sent", itemID: object["item_id"] as? String, seq: object["seq"] as? Int ?? 0)))
        } else {
            finish(id, .failure(SocketSendError.refused(code: object["code"] as? String ?? "failed", message: object["message"] as? String ?? "The Mac refused the message.")))
        }
        return true
    }

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
            opened(socket)
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
                    if answer(data) { continue }
                    guard let event = try? decoder.decode(RemoteEvent.self, from: data) else { continue }
                    attempt = 0
                    switch event.kind {
                    case RemoteEvent.hello:
                        announce((try? JSONSerialization.jsonObject(with: data)).flatMap { ($0 as? [String: Any])?["capabilities"] as? [String] } ?? [])
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
                closed(socket)
                if (socket.response as? HTTPURLResponse)?.statusCode == 401 {
                    continuation.yield(.unauthorized)
                    continuation.finish()
                    return
                }
            }
            closed(socket)
            socket.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { break }
            try? await Task.sleep(for: backoff.delay(attempt: attempt))
            attempt += 1
        }
        continuation.finish()
    }
}
#endif
