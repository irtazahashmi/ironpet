#if canImport(Darwin)
import Foundation

/// What the event socket tells its reader.
public enum EventSignal: Equatable, Sendable {
    /// The socket is open (first time or after a drop). The reader reloads what it shows, since events may have passed before it opened.
    case connected
    case event(RemoteEvent)
    /// The Mac no longer holds the events after the last `seq`, or the `seq` came from an earlier launch of the Mac. The reader reads
    /// everything again.
    case resync
    /// The socket is open again and the Mac replayed the `replayed` events the phone missed, each as an `.event` before this signal.
    /// The reader does not read everything again. It does whatever waited for the connection, such as sending queued messages.
    case resumed(replayed: Int)
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

/// Where the phone keeps the last event `seq` it applied, and the `epoch` of the Mac launch that numbered it, so a resume works after
/// the app restarted too.
public protocol EventResumeStoring: Sendable {
    func load() -> (seq: Int, epoch: String?)?
    func save(seq: Int, epoch: String?)
}

/// Keeps the resume point in `UserDefaults`, one pair of keys per Mac the phone is paired with.
public final class DefaultsResumeStore: EventResumeStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let seqKey: String
    private let epochKey: String

    public init(defaults: UserDefaults = .standard, key: String = "events.resume") {
        self.defaults = defaults
        seqKey = key + ".seq"
        epochKey = key + ".epoch"
    }

    public func load() -> (seq: Int, epoch: String?)? {
        guard defaults.object(forKey: seqKey) != nil else { return nil }
        return (defaults.integer(forKey: seqKey), defaults.string(forKey: epochKey))
    }

    public func save(seq: Int, epoch: String?) {
        defaults.set(seq, forKey: seqKey)
        defaults.set(epoch, forKey: epochKey)
    }

    /// Forgets this store's resume point.
    public func clear() {
        defaults.removeObject(forKey: seqKey)
        defaults.removeObject(forKey: epochKey)
    }

    /// The prefix of every key the app gives its stores, one per paired Mac.
    public static let keyPrefix = "events.resume."

    /// Forgets the resume points of every Mac this phone was paired with. The phone calls it when it unpairs and when it pairs again,
    /// since a point from one Mac means nothing to another.
    public static func clearAll(defaults: UserDefaults = .standard) {
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(keyPrefix) { defaults.removeObject(forKey: name) }
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
    /// The `epoch` of the Mac launch that numbered `last`. Nil until a Mac that sends one has said hello.
    private var epoch: String?
    private let store: (any EventResumeStoring)?
    private let saveQueue = DispatchQueue(label: "ironpet.event-resume-save")
    private var savePending = false
    /// The open socket, and whether its hello announced `chat.send`.
    private var open: URLSessionWebSocketTask?
    private var chatSendAnnounced = false
    private var waiting: [String: CheckedContinuation<ChatAck, Error>] = [:]
    /// The back-off wait between two tries, so `reconnectNow` can end it early.
    private var pause: Task<Void, Never>?
    /// Set by `reconnectNow`: the next try starts from the first delay.
    private var resetRequested = false

    public init(client: IronPetClient, backoff: Backoff = Backoff(), store: (any EventResumeStoring)? = nil) {
        self.client = client
        self.backoff = backoff
        self.store = store
        if let saved = store?.load() {
            last = saved.seq
            epoch = saved.epoch
        }
    }

    /// The highest `seq` seen so far.
    public var lastSeq: Int? { lock.lock(); defer { lock.unlock() }; return last }

    /// Tries the socket now instead of waiting out the back-off, and starts the next back-off from the first delay. The app calls it when
    /// it comes to the foreground, since the socket was dropped while it was in the background.
    public func reconnectNow() {
        lock.lock()
        resetRequested = true
        let wait = pause
        lock.unlock()
        wait?.cancel()
    }

    private func setPause(_ task: Task<Void, Never>?) { lock.lock(); pause = task; lock.unlock() }
    private func takeReset() -> Bool { lock.lock(); defer { lock.unlock() }; let reset = resetRequested; resetRequested = false; return reset }

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

    private func record(_ seq: Int) {
        lock.lock()
        last = max(last ?? 0, seq)
        lock.unlock()
        scheduleSave()
    }

    /// Writes the resume point on a queue of its own, so the loop that reads the socket never waits for `UserDefaults`. Events that
    /// arrive while a write is waiting share it, and it saves the newest values.
    private func scheduleSave() {
        guard let store else { return }
        lock.lock()
        if savePending { lock.unlock(); return }
        savePending = true
        lock.unlock()
        saveQueue.async { [self] in
            lock.lock()
            savePending = false
            let saved = (last, epoch)
            lock.unlock()
            if let seq = saved.0 { store.save(seq: seq, epoch: saved.1) }
        }
    }

    /// Moves the resume point to `seq` of the Mac launch `epoch`, which may be lower than the old one after a Mac restart.
    private func reset(to seq: Int, epoch newEpoch: String?) {
        lock.lock()
        last = seq
        if let newEpoch { epoch = newEpoch }
        lock.unlock()
        scheduleSave()
    }

    private var resumeEpoch: String? { lock.lock(); defer { lock.unlock() }; return epoch }

    /// Ends when the consumer stops iterating or the token is refused.
    public func signals() -> AsyncStream<EventSignal> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func socketURL() -> URLRequest {
        var items: [URLQueryItem] = []
        if let seq = lastSeq {
            items.append(URLQueryItem(name: "since", value: String(seq)))
            if let epoch = resumeEpoch { items.append(URLQueryItem(name: "epoch", value: epoch)) }
        }
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
        var helloEpoch: String?
        while !Task.isCancelled {
            let request = socketURL()
            // Whether this socket asks the Mac to replay what the phone missed.
            let resuming = request.url?.query?.contains("since=") == true
            let socket = client.session.webSocketTask(with: request)
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
                        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let capabilities = object?["capabilities"] as? [String] ?? []
                        helloEpoch = object?["epoch"] as? String
                        announce(capabilities)
                        if lastSeq == nil { reset(to: event.seq, epoch: helloEpoch) }
                        // A Mac that can resume answers a resuming phone with the missed events and then `resumed`, or with `resync`. Any
                        // other Mac sends neither, so the reader reads everything again as it always did.
                        if resuming, capabilities.contains("events.resume") { continue }
                        continuation.yield(.connected)
                    case RemoteEvent.resync:
                        reset(to: event.seq, epoch: helloEpoch)
                        continuation.yield(.resync)
                    case RemoteEvent.resumed:
                        // Everything up to `seq` is delivered, including events the bus merged into later ones.
                        reset(to: event.seq, epoch: helloEpoch)
                        let replayed = (try? JSONSerialization.jsonObject(with: data)).flatMap { ($0 as? [String: Any])?["replayed"] as? Int } ?? 0
                        continuation.yield(.resumed(replayed: replayed))
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
            let delay = backoff.delay(attempt: attempt)
            let pause = Task { do { try await Task.sleep(for: delay) } catch {} }
            setPause(pause)
            await pause.value
            setPause(nil)
            // `reconnectNow` ended the wait early, so the next try starts from the first delay again.
            attempt = takeReset() ? 0 : attempt + 1
        }
        continuation.finish()
    }
}
#endif
