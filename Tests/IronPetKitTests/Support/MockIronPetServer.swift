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
    private var _pet = RemotePet(name: "Ghost", mood: "idle", badge: 0, tricks: ["Wave", "Jump", "Dance", "Zoomies"])
    private var _bubbles: [RemoteBubble] = MockIronPetServer.sampleBubbles
    private var _agents: [RemoteAgent] = MockIronPetServer.sampleAgents
    private var _alerts: [RemoteAlert] = MockIronPetServer.sampleAlerts
    private var _today: [String: RemoteToday] = ["brief": MockIronPetServer.sampleBrief, "recap": MockIronPetServer.sampleRecap]
    private var _assetData: [String: Data] = [:]
    private var _assets: [RemoteAsset] = []
    private var _chat = MockIronPetServer.sampleChat
    private var _chatThreads = MockIronPetServer.sampleThreads
    private var _threadItems: [String: [RemoteChatItem]] = ["th-1": [RemoteChatItem(id: "th-1-u", kind: "user", text: "Old question"), RemoteChatItem(id: "th-1-a", kind: "assistant", text: "Old answer")]]
    private var _openConflict: String?
    private var _uploadFails = false
    private var _uploads: [String: Data] = [:]
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

    static let sampleBubbles: [RemoteBubble] = [
        RemoteBubble(id: "session:a", symbol: "checkmark.circle.fill", title: "demo-app: Done", body: "Edited 3 files",
                     actions: [RemoteBubbleAction(id: "act-open", title: "Open", style: "primary"), RemoteBubbleAction(id: "act-snooze", title: "Snooze")]),
        RemoteBubble(id: "approval:1", symbol: "hand.raised.fill", title: "Ghost wants to: Run this command?", macOnly: true),
    ]

    static let sampleAgents: [RemoteAgent] = [
        RemoteAgent(id: "s-needs", status: .needsInput, statusLabel: "Needs input", workspace: "demo-app", prompt: "Fix the login test",
                    detail: "Allow npm test?", summary: "Edited login.ts"),
        RemoteAgent(id: "s-run", source: "codex", sourceName: "Codex", status: .running, statusLabel: "Running", workspace: "api"),
        RemoteAgent(id: "s-done", status: .done, statusLabel: "Done", workspace: "docs", summary: "Edited 2 files", editedFiles: ["/a/README.md", "/a/SPEC.md"],
                    lastResponse: "Updated the docs."),
    ]

    static let sampleAlerts: [RemoteAlert] = [
        RemoteAlert(id: "al-ci", title: "CI failed on main", subtitle: "build #42", label: "CI failed", mood: "failed", url: "https://example.com/build/42"),
        RemoteAlert(id: "al-pr", title: "Review requested", label: "Review", canAsk: false),
    ]

    static let sampleBrief = RemoteToday(kind: "brief", title: "Morning brief", lines: ["1 task needs you"], sections: [
        TodaySection(id: "tasks", title: "Needs you", items: [TodayItem(id: "i-task", symbol: "checklist", title: "Review the contract", target: TodayTarget(type: .task, id: "t-needs"))]),
        TodaySection(id: "agents", title: "Agents", items: [TodayItem(id: "i-session", symbol: "terminal", title: "demo-app", target: TodayTarget(type: .session, id: "s-needs"))]),
        TodaySection(id: "alerts", title: "Alerts", items: [TodayItem(id: "i-alert", symbol: "exclamationmark.triangle", title: "CI failed", target: TodayTarget(type: .alert, id: "al-ci", url: "https://example.com/build/42"))]),
        TodaySection(id: "meetings", title: "Meetings", items: [TodayItem(id: "i-meeting", symbol: "person.2", title: "Standup", target: TodayTarget(type: .meeting, id: "2026-01-01-standup"))]),
    ])

    static let sampleRecap = RemoteToday(kind: "recap", title: "Today's recap", sections: [
        TodaySection(id: "done", title: "Finished", items: [TodayItem(id: "r-1", title: "Ship the beta", target: TodayTarget(type: .task, id: "t-done"))]),
    ])

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

    var pet: RemotePet { get { lock.lock(); defer { lock.unlock() }; return _pet } set { lock.lock(); _pet = newValue; lock.unlock() } }
    var bubbles: [RemoteBubble] { get { lock.lock(); defer { lock.unlock() }; return _bubbles } set { lock.lock(); _bubbles = newValue; lock.unlock() } }
    var agents: [RemoteAgent] { get { lock.lock(); defer { lock.unlock() }; return _agents } set { lock.lock(); _agents = newValue; lock.unlock() } }
    var alerts: [RemoteAlert] { get { lock.lock(); defer { lock.unlock() }; return _alerts } set { lock.lock(); _alerts = newValue; lock.unlock() } }
    /// The sheet the Mac serves as `pet.sprite`. Setting a new one changes the manifest, like picking another pet on the Mac.
    func setSprite(_ data: Data) {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let atlas = Atlas.load(data: data)
        lock.lock()
        _assetData[hash] = data
        _assets.removeAll { $0.id == "pet.sprite" }
        _assets.insert(RemoteAsset(id: "pet.sprite", name: "sheet.png", sha256: hash, bytes: data.count, width: atlas == nil ? nil : Atlas.width,
                                   height: atlas.map { $0.rows.count * Int(Atlas.cell.height) }), at: 0)
        lock.unlock()
    }

    /// The chat the Mac has open, as `GET /v1/chat/current` answers it. Change it, then `publish` the event a real Mac would.
    var chat: RemoteChatSnapshot { get { lock.lock(); defer { lock.unlock() }; return _chat } set { lock.lock(); _chat = newValue; lock.unlock() } }
    var chatThreads: [RemoteChatThread] { get { lock.lock(); defer { lock.unlock() }; return _chatThreads } set { lock.lock(); _chatThreads = newValue; lock.unlock() } }
    /// When set, opening a thread or starting a new chat answers 409 with this text, as a Mac with a running turn does.
    var openConflict: String? { get { lock.lock(); defer { lock.unlock() }; return _openConflict } set { lock.lock(); _openConflict = newValue; lock.unlock() } }
    /// True answers every upload with 500.
    var uploadFails: Bool { get { lock.lock(); defer { lock.unlock() }; return _uploadFails } set { lock.lock(); _uploadFails = newValue; lock.unlock() } }
    /// The bytes of an upload by id.
    func uploaded(_ id: String) -> Data? { lock.lock(); defer { lock.unlock() }; return _uploads[id] }

    /// Appends `text` to an assistant item and sends `chat.item` for it, as one streamed chunk does on the Mac. Makes the item when it is new.
    func streamChunk(item id: String, _ text: String) {
        lock.lock()
        if let index = _chat.items.firstIndex(where: { $0.id == id }) { _chat.items[index].text = (_chat.items[index].text ?? "") + text }
        else { _chat.items.append(RemoteChatItem(id: id, kind: "assistant", date: Date(), text: text)) }
        _chat.running = true
        lock.unlock()
        publish(RemoteEvent.chatItem, id: id)
    }

    /// Ends the running turn.
    func finishTurn() {
        lock.lock(); _chat.running = false; _chat.state = "done"; lock.unlock()
        publish(RemoteEvent.chatState)
    }

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
        let reason = [200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict",
                      413: "Content Too Large", 500: "Internal Server Error"][status] ?? "OK"
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
        if routeResources(request, parts, connection) || routeChat(request, parts, connection) { return }
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

    // MARK: Phase 2 routes

    /// Answers the pet, bubble, agent, alert, today and asset routes. Returns false for any other request.
    private func routeResources(_ request: Recorded, _ parts: [String], _ connection: NWConnection) -> Bool {
        guard parts.count >= 2, parts[0] == "v1" else { return false }
        let get = request.method == "GET", post = request.method == "POST"
        switch (parts[1], parts.count) {
        case ("pet", 2) where get: respond(connection, 200, pet)
        case ("pet", 4) where post && parts[2] == "tricks": respond(connection, 200, Data("{}".utf8))
        case ("bubbles", 2) where get: respond(connection, 200, BubbleListResponse(bubbles: bubbles))
        case ("bubbles", 5) where post && parts[3] == "actions":
            lock.lock()
            let found = _bubbles.first { $0.id == parts[2] }
            let known = found.map { !$0.macOnly && $0.actions.contains { $0.id == parts[4] } } ?? false
            if known { _bubbles.removeAll { $0.id == parts[2] } }
            lock.unlock()
            guard known else { fail(connection, 404, "not_found", "no such action"); return true }
            respond(connection, 200, Data("{}".utf8))
            publish(RemoteEvent.bubbleDismissed, id: parts[2])
        case ("agents", 2) where get: respond(connection, 200, AgentListResponse(agents: agents))
        case ("agents", 3) where get:
            guard let agent = agents.first(where: { $0.id == parts[2] }) else { fail(connection, 404, "not_found", "no session"); return true }
            respond(connection, 200, agent)
        case ("agents", 4) where post && parts[3] == "acknowledge":
            lock.lock()
            let known = _agents.contains { $0.id == parts[2] }
            _agents.removeAll { $0.id == parts[2] }
            lock.unlock()
            guard known else { fail(connection, 404, "not_found", "no session"); return true }
            respond(connection, 200, Data("{}".utf8))
            publish(RemoteEvent.agentsChanged)
        case ("agents", 4) where post && parts[3] == "ask": respond(connection, 200, Data(#"{"outcome":"sent"}"#.utf8))
        case ("alerts", 2) where get: respond(connection, 200, AlertListResponse(alerts: alerts))
        case ("alerts", 3) where post && parts[2] == "dismiss-all":
            lock.lock(); _alerts = []; lock.unlock()
            respond(connection, 200, Data("{}".utf8))
            publish(RemoteEvent.alertsChanged)
        case ("alerts", 4) where post && parts[3] == "dismiss":
            lock.lock()
            let known = _alerts.contains { $0.id == parts[2] }
            _alerts.removeAll { $0.id == parts[2] }
            lock.unlock()
            guard known else { fail(connection, 404, "not_found", "no alert"); return true }
            respond(connection, 200, Data("{}".utf8))
            publish(RemoteEvent.alertsChanged)
        case ("alerts", 4) where post && parts[3] == "ask": respond(connection, 200, Data(#"{"outcome":"sent"}"#.utf8))
        case ("today", 2) where get:
            let kind = request.query.split(separator: "&").compactMap { $0.hasPrefix("kind=") ? String($0.dropFirst(5)) : nil }.first ?? "brief"
            lock.lock(); let today = _today[kind]; lock.unlock()
            guard let today else { fail(connection, 400, "invalid", "kind must be brief or recap"); return true }
            respond(connection, 200, today)
        case ("assets", 3) where get && parts[2] == "manifest":
            lock.lock(); let assets = _assets; lock.unlock()
            respond(connection, 200, AssetManifestResponse(assets: assets))
        case ("assets", 3) where get:
            lock.lock(); let data = _assetData[parts[2]]; lock.unlock()
            guard let data else { fail(connection, 404, "not_found", "no asset"); return true }
            respond(connection, 200, data)
        default: return false
        }
        return true
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

// MARK: Phase 3 chat routes

extension MockIronPetServer {
    static let sampleChat = RemoteChatSnapshot(
        threadID: "th-now", title: "Fix the login test", state: "idle", folderLabel: "demo-app",
        items: [RemoteChatItem(id: "m-1", kind: "user", date: Date(timeIntervalSince1970: 1_700_000_000), text: "Why does the login test fail?"),
                RemoteChatItem(id: "m-2", kind: "assistant", date: Date(timeIntervalSince1970: 1_700_000_010), text: "The **fixture** is stale.")])

    static let sampleThreads = [RemoteChatThread(id: "th-1", title: "Old chat", folderLabel: "demo-app"),
                                RemoteChatThread(id: "th-2", title: "Another chat", folderLabel: "api", updated: Date(timeIntervalSince1970: 1_700_000_500))]

    /// Answers the chat and upload routes. Returns false for any other request.
    fileprivate func routeChat(_ request: Recorded, _ parts: [String], _ connection: NWConnection) -> Bool {
        guard parts.count >= 2, parts[0] == "v1" else { return false }
        let get = request.method == "GET", post = request.method == "POST"
        if parts[1] == "uploads", post, parts.count == 2 {
            if uploadFails { fail(connection, 500, "failed", "the upload failed"); return true }
            let id = "up-\(UUID().uuidString.prefix(6))"
            lock.lock(); _uploads[id] = request.body; lock.unlock()
            let name = (request.headers["x-file-name"] ?? "file").removingPercentEncoding ?? "file"
            respond(connection, 201, RemoteUpload(id: id, fileName: name, storedName: "\(id.suffix(6))-\(name)", bytes: request.body.count))
            return true
        }
        guard parts[1] == "chat" else { return false }
        switch (parts.count, parts.dropFirst(2).first ?? "") {
        case (3, "current") where get: respond(connection, 200, chat)
        case (4, "messages") where get:
            guard let item = chat.items.first(where: { $0.id == parts[3] }) else { fail(connection, 404, "not_found", "no message"); return true }
            respond(connection, 200, item)
        case (3, "threads") where get: respond(connection, 200, ChatThreadListResponse(threads: chatThreads))
        case (4, "threads") where get:
            lock.lock(); let items = _threadItems[parts[3]]; lock.unlock()
            guard let thread = chatThreads.first(where: { $0.id == parts[3] }), let items else { fail(connection, 404, "not_found", "no thread"); return true }
            respond(connection, 200, RemoteChatThreadDetail(thread: thread, items: items))
        case (4, "current") where post && parts[3] == "messages":
            guard let text = request.json["text"] as? String, !text.isEmpty || request.json["upload_ids"] != nil else { fail(connection, 400, "invalid", "the message is empty"); return true }
            lock.lock()
            let queued = _chat.running
            let id = "m-\(_chat.items.count + 1)"
            if queued { _chat.queue.append(RemoteQueued(id: "q-\(id)", text: text)) }
            else { _chat.items.append(RemoteChatItem(id: id, kind: "user", date: Date(), origin: "ios", text: text)); _chat.running = true; _chat.state = "running" }
            lock.unlock()
            respond(connection, 200, RemoteSendResult(outcome: queued ? "queued" : "sent"))
            publish(queued ? RemoteEvent.chatState : RemoteEvent.chatItem, id: queued ? "queue" : id)
        case (4, "current") where post && parts[3] == "stop":
            lock.lock(); _chat.running = false; _chat.state = "idle"; lock.unlock()
            respond(connection, 200, Data(#"{"stopped":true}"#.utf8))
            publish(RemoteEvent.chatState)
        case (4, "open") where post, (3, "new") where post:
            if let conflict = openConflict { fail(connection, 409, "conflict", conflict); return true }
            if parts[2] == "open" {
                lock.lock()
                let items = _threadItems[parts[3]] ?? []
                _chat.threadID = parts[3]; _chat.items = items
                lock.unlock()
            } else {
                lock.lock(); _chat.threadID = nil; _chat.items = []; _chat.title = "New chat"; lock.unlock()
            }
            respond(connection, 200, Data("{}".utf8))
            publish(RemoteEvent.chatItem)
        case (4, "approvals") where post:
            lock.lock()
            let known = _chat.approvals.contains { $0.id == parts[3] }
            _chat.approvals.removeAll { $0.id == parts[3] }
            lock.unlock()
            guard known else { fail(connection, 404, "not_found", "that approval is no longer waiting"); return true }
            respond(connection, 200, Data(#"{"allowed":true}"#.utf8))
            publish(RemoteEvent.chatState, id: "approvals")
        case (4, "forms") where post, (5, "forms") where post:
            lock.lock()
            let known = _chat.forms.contains { $0.id == parts[3] }
            let closes = parts.count == 5
            if known, closes { _chat.forms.removeAll { $0.id == parts[3] } }
            lock.unlock()
            guard known else { fail(connection, 404, "not_found", "that question is no longer waiting"); return true }
            respond(connection, 200, Data("{}".utf8))
            publish(RemoteEvent.chatState, id: "forms")
        default: return false
        }
        return true
    }
}
