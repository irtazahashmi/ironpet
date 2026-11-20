import CryptoKit
import Foundation
import IronPetKit
import Network

/// A stand-in for the Mac's remote API on 127.0.0.1, for `swift test` and the iOS unit and UI tests. It serves canned DTOs, answers
/// pairing as configured, records every request and speaks enough WebSocket to push events. The same file is compiled into the iOS test targets.
final class MockIronPetServer: @unchecked Sendable {
    enum PairingOutcome { case allow, deny, expire }

    struct Recorded: Equatable {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
        var body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var line: String { "\(method) \(path)" }
    }

    let code = "mock-pairing-code"
    let token = "ipt_mock-token"
    let deviceID = "device-1"

    private let queue = DispatchQueue(label: "mock-ironpet-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sockets: [NWConnection] = []
    private var _tasks: [RemoteTask]
    private var _suggestions: [RemoteSuggestion]
    private var _requests: [Recorded] = []
    private var _outcome: PairingOutcome = .allow
    private var _pendingPolls = 1
    private var polls = 0
    private var _tokenValid = true
    private var _seq = 0
    private var buffer: [RemoteEvent] = []
    private var _gapOnNextConnect = false
    private var _socketURLs: [String] = []
    private let encoder = WireJSON.makeEncoder()
    private(set) var port: UInt16 = 0
    private let tlsIdentity: SecIdentity?

    /// With `tlsIdentity` the server speaks HTTPS using that certificate, for the pinning tests.
    init(tasks: [RemoteTask] = MockIronPetServer.sampleTasks, suggestions: [RemoteSuggestion] = MockIronPetServer.sampleSuggestions,
         tlsIdentity: SecIdentity? = nil) {
        self.tlsIdentity = tlsIdentity
        _tasks = tasks
        _suggestions = suggestions
    }

    static let sampleTasks: [RemoteTask] = [
        RemoteTask(id: "t-needs", title: "Review the contract", status: .needsYou),
        RemoteTask(id: "t-progress", title: "Write the release notes", status: .inProgress),
        RemoteTask(id: "t-backlog", title: "Clean up the inbox", status: .backlog),
        RemoteTask(id: "t-waiting", title: "Reply from legal", status: .needsYou, waitingOn: "Ana"),
        RemoteTask(id: "t-done", title: "Ship the beta", status: .done, closed: Date(timeIntervalSince1970: 1_700_000_100)),
    ]

    static let sampleSuggestions: [RemoteSuggestion] = [
        RemoteSuggestion(id: "s-1", title: "Send the notes to Bo", origin: "meeting"),
        RemoteSuggestion(id: "s-2", title: "Check the flaky build", origin: "automation", originDetail: "CI watcher (a1)"),
    ]

    // MARK: State

    var baseURL: URL { URL(string: "\(tlsIdentity == nil ? "http" : "https")://127.0.0.1:\(port)")! }
    var pairingLink: String { pairingLink() }
    func pairingLink(fingerprint: String?) -> String { pairingLink(fingerprint) }
    private func pairingLink(_ fingerprint: String? = nil) -> String {
        "ironpet://pair?u=\(baseURL.absoluteString)&c=\(code)" + (fingerprint.map { "&f=\($0)" } ?? "")
    }

    var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return _requests }
    var tasks: [RemoteTask] { get { lock.lock(); defer { lock.unlock() }; return _tasks } set { lock.lock(); _tasks = newValue; lock.unlock() } }
    var suggestions: [RemoteSuggestion] { get { lock.lock(); defer { lock.unlock() }; return _suggestions } set { lock.lock(); _suggestions = newValue; lock.unlock() } }
    var outcome: PairingOutcome { get { lock.lock(); defer { lock.unlock() }; return _outcome } set { lock.lock(); _outcome = newValue; lock.unlock() } }
    /// How many polls answer `pending` before the outcome.
    var pendingPolls: Int { get { lock.lock(); defer { lock.unlock() }; return _pendingPolls } set { lock.lock(); _pendingPolls = newValue; lock.unlock() } }
    /// False answers every token request with 401.
    var tokenValid: Bool { get { lock.lock(); defer { lock.unlock() }; return _tokenValid } set { lock.lock(); _tokenValid = newValue; lock.unlock() } }
    /// The next socket that connects gets `resync` after `hello`, as if the buffer had lost its events.
    var gapOnNextConnect: Bool { get { lock.lock(); defer { lock.unlock() }; return _gapOnNextConnect } set { lock.lock(); _gapOnNextConnect = newValue; lock.unlock() } }
    /// The request target of every socket upgrade, such as `/v1/events?since=3`.
    var socketURLs: [String] { lock.lock(); defer { lock.unlock() }; return _socketURLs }
    var openSocketCount: Int { lock.lock(); defer { lock.unlock() }; return sockets.count }

    func count(_ line: String) -> Int { requests.filter { $0.line == line }.count }

    // MARK: Lifecycle

    func start() throws {
        var parameters = NWParameters.tcp
        if let tlsIdentity {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(tlsIdentity)!)
            parameters = NWParameters(tls: options)
        }
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.port = port
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        dropSockets()
    }

    // MARK: Events

    /// Sends an event to every open socket and keeps it for replay.
    @discardableResult
    func publish(_ kind: String, id: String? = nil) -> Int {
        lock.lock()
        _seq += 1
        let event = RemoteEvent(seq: _seq, kind: kind, at: Date(), id: id)
        buffer.append(event)
        let open = sockets
        lock.unlock()
        for socket in open { sendText(event, on: socket) }
        return event.seq
    }

    func dropSockets() {
        lock.lock()
        let open = sockets
        sockets = []
        lock.unlock()
        for socket in open { socket.cancel() }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, pending: Data())
    }

    private func read(_ connection: NWConnection, pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = pending
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.handle(request, on: connection)
            } else if error == nil, !done {
                self.read(connection, pending: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private static func parse(_ data: Data) -> Recorded? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = head[0].split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        let target = String(start[1])
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        return Recorded(method: String(start[0]), path: parts[0], query: parts.count > 1 ? parts[1] : "", headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ body: Data) {
        let reason = [200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "OK"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        connection.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond<T: Encodable>(_ connection: NWConnection, _ status: Int, _ value: T) {
        respond(connection, status, (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    private func fail(_ connection: NWConnection, _ status: Int, _ code: String, _ message: String) {
        respond(connection, status, APIErrorBody(error: .init(code: code, message: message)))
    }

    private func handle(_ request: Recorded, on connection: NWConnection) {
        lock.lock()
        _requests.append(request)
        let valid = _tokenValid
        lock.unlock()

        let open = request.path == APIPath.pair || request.path.hasPrefix("/v1/pair/")
        if !open, !(valid && request.headers["authorization"] == "Bearer \(token)") {
            return fail(connection, 401, "unauthorized", "unauthorized")
        }
        let parts = request.path.split(separator: "/").map(String.init)
        switch (request.method, parts.count) {
        case ("POST", 2) where request.path == APIPath.pair: pair(request, connection)
        case ("GET", 3) where parts[1] == "pair": poll(parts[2], request, connection)
        case ("GET", 3) where request.path == APIPath.deviceMe: respond(connection, 200, RemoteDevice(id: deviceID, name: "Test phone"))
        case ("DELETE", 3) where request.path == APIPath.deviceMe:
            lock.lock(); _tokenValid = false; lock.unlock()
            respond(connection, 200, Data(#"{"revoked":true}"#.utf8))
        case ("GET", 2) where parts[1] == "events": upgrade(request, connection)
        case ("GET", 2) where parts[1] == "tasks": respond(connection, 200, TaskListResponse(tasks: tasks))
        case ("GET", 2) where parts[1] == "suggestions": respond(connection, 200, SuggestionListResponse(suggestions: suggestions))
        case ("GET", 3) where parts[1] == "tasks": detail(parts[2], connection)
        case ("PATCH", 3) where parts[1] == "tasks": patch(parts[2], request, connection)
        case ("POST", 4) where parts[1] == "tasks" && parts[3] == "close": close(parts[2], request, connection)
        case ("POST", 4) where parts[1] == "suggestions" && parts[3] == "accept": accept(parts[2], connection)
        case ("POST", 4) where parts[1] == "suggestions" && parts[3] == "reject": reject(parts[2], connection)
        default: fail(connection, 404, "not_found", "not found")
        }
    }

    private func pair(_ request: Recorded, _ connection: NWConnection) {
        guard request.json["code"] as? String == code else { return fail(connection, 401, "unauthorized", "unauthorized") }
        respond(connection, 202, PairAccepted(pairingID: "pairing-1", secret: "pairing-secret", expiresIn: 300))
    }

    private func poll(_ id: String, _ request: Recorded, _ connection: NWConnection) {
        guard request.headers["x-pairing-secret"] == "pairing-secret" else { return fail(connection, 401, "unauthorized", "unauthorized") }
        lock.lock()
        polls += 1
        let waiting = polls <= _pendingPolls
        let result = _outcome
        lock.unlock()
        if waiting { return respond(connection, 200, PairPoll(status: .pending)) }
        switch result {
        case .allow: respond(connection, 200, PairPoll(status: .allowed, token: token, deviceID: deviceID))
        case .deny: respond(connection, 200, PairPoll(status: .denied))
        case .expire: respond(connection, 200, PairPoll(status: .expired))
        }
    }

    // MARK: Task routes

    private func detail(_ id: String, _ connection: NWConnection) {
        guard let task = tasks.first(where: { $0.id == id }) else { return fail(connection, 404, "not_found", "no task \(id)") }
        let history = [RemoteTaskEvent(at: Date(timeIntervalSince1970: 1_700_000_000), by: "user", kind: "created", detail: task.title)]
        respond(connection, 200, RemoteTaskDetail(task: task, history: history))
    }

    private func patch(_ id: String, _ request: Recorded, _ connection: NWConnection) {
        lock.lock()
        guard let index = _tasks.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return fail(connection, 404, "not_found", "no task \(id)")
        }
        if let raw = request.json["status"] as? String, let status = TaskStatus(rawValue: raw) { _tasks[index].status = status }
        let task = _tasks[index]
        lock.unlock()
        respond(connection, 200, task)
        publish(RemoteEvent.tasksChanged, id: id)
    }

    private func close(_ id: String, _ request: Recorded, _ connection: NWConnection) {
        guard (request.json["note"] as? String)?.isEmpty == false else { return fail(connection, 400, "invalid", "note is required") }
        lock.lock()
        guard let index = _tasks.firstIndex(where: { $0.id == id }) else {
            lock.unlock(); return fail(connection, 404, "not_found", "no task \(id)")
        }
        _tasks[index].status = .done
        _tasks[index].closed = Date()
        let task = _tasks[index]
        lock.unlock()
        respond(connection, 200, task)
        publish(RemoteEvent.tasksChanged, id: id)
    }

    private func accept(_ id: String, _ connection: NWConnection) {
        lock.lock()
        guard let index = _suggestions.firstIndex(where: { $0.id == id }) else {
            lock.unlock(); return fail(connection, 404, "not_found", "no suggestion \(id)")
        }
        let suggestion = _suggestions.remove(at: index)
        let task = RemoteTask(id: "t-from-\(id)", title: suggestion.title, status: .backlog, source: suggestion.origin)
        _tasks.append(task)
        lock.unlock()
        respond(connection, 200, task)
        publish(RemoteEvent.tasksChanged, id: task.id)
        publish(RemoteEvent.suggestionsChanged)
    }

    private func reject(_ id: String, _ connection: NWConnection) {
        lock.lock()
        guard let index = _suggestions.firstIndex(where: { $0.id == id }) else {
            lock.unlock(); return fail(connection, 404, "not_found", "no suggestion \(id)")
        }
        _suggestions.remove(at: index)
        lock.unlock()
        respond(connection, 200, Data(#"{"rejected":"\#(id)"}"#.utf8))
        publish(RemoteEvent.suggestionsChanged)
    }

    // MARK: WebSocket

    private func upgrade(_ request: Recorded, _ connection: NWConnection) {
        guard let key = request.headers["sec-websocket-key"] else { return fail(connection, 426, "upgrade_required", "this route is a WebSocket") }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        let since = request.query.split(separator: "&").compactMap { pair -> Int? in
            let kv = pair.split(separator: "=")
            return kv.count == 2 && kv[0] == "since" ? Int(kv[1]) : nil
        }.first
        lock.lock()
        _socketURLs.append(request.query.isEmpty ? request.path : "\(request.path)?\(request.query)")
        let gap = _gapOnNextConnect
        _gapOnNextConnect = false
        let hello = RemoteEvent(seq: _seq, kind: RemoteEvent.hello)
        let replay = since.map { floor in buffer.filter { $0.seq > floor } } ?? []
        lock.unlock()
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.sendText(hello, on: connection)
            if gap { self.sendText(RemoteEvent(seq: self.currentSeq, kind: RemoteEvent.resync), on: connection) } else {
                for event in replay { self.sendText(event, on: connection) }
            }
            self.lock.lock(); self.sockets.append(connection); self.lock.unlock()
            self.drain(connection)
        })
    }

    private var currentSeq: Int { lock.lock(); defer { lock.unlock() }; return _seq }

    /// Reads and drops client frames so a close from the phone ends the socket.
    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if data == nil || done || error != nil {
                self.lock.lock(); self.sockets.removeAll { $0 === connection }; self.lock.unlock()
                connection.cancel()
                return
            }
            self.drain(connection)
        }
    }

    private func sendText(_ event: RemoteEvent, on connection: NWConnection) {
        let payload = (try? encoder.encode(event)) ?? Data()
        var frame = Data([0x81])
        if payload.count < 126 { frame.append(UInt8(payload.count)) } else {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}
