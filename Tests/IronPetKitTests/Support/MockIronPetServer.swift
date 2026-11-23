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
    private var _brokenRoutes: [String: Int] = [:]
    private var _uploads: [String: Data] = [:]
    private var _chatImages: [String: Data] = [:]
    private var _chatImageHits = 0
    private var _previews: [String: (data: Data, contentType: String, truncated: Bool)] = [:]
    private var _uploadNames: [String: String] = [:]
    private var _uploadDelay: TimeInterval = 0
    private var _sendFails = false
    private var _chatReadFailures = 0
    private var _sendDelay: TimeInterval = 0
    private var _sendPushesFirst = false
    private var _legacyEvents = false
    private var _messageReadDelay: TimeInterval = 0
    private var _messageReads = 0
    private var _readsInFlight = 0
    private var _maxReadsInFlight = 0
    fileprivate var _p4 = MockPhaseFour()
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

    /// The custom chat background the Mac serves as `chat.background`, as if it was picked on the Mac. The hash is the image's SHA-256.
    @discardableResult
    func setBackgroundImage(_ data: Data) -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        _assetData[hash] = data
        _assets.removeAll { $0.id == "chat.background" }
        _assets.append(RemoteAsset(id: "chat.background", kind: "background", name: "custom.jpg", sha256: hash, bytes: data.count, contentType: "image/jpeg"))
        _p4.config.chat.background = "custom"
        _pet.background = "custom"
        _pet.backgroundAsset = "chat.background"
        lock.unlock()
        return hash
    }

    /// The chat the Mac has open, as `GET /v1/chat/current` answers it. Change it, then `publish` the event a real Mac would.
    var chat: RemoteChatSnapshot { get { lock.lock(); defer { lock.unlock() }; return _chat } set { lock.lock(); _chat = newValue; lock.unlock() } }
    var chatThreads: [RemoteChatThread] { get { lock.lock(); defer { lock.unlock() }; return _chatThreads } set { lock.lock(); _chatThreads = newValue; lock.unlock() } }
    /// When set, opening a thread or starting a new chat answers 409 with this text, as a Mac with a running turn does.
    var openConflict: String? { get { lock.lock(); defer { lock.unlock() }; return _openConflict } set { lock.lock(); _openConflict = newValue; lock.unlock() } }
    /// Routes that answer with a fixed status instead of their data, by exact path. Status 200 answers a body the client cannot decode.
    var brokenRoutes: [String: Int] { get { lock.lock(); defer { lock.unlock() }; return _brokenRoutes } set { lock.lock(); _brokenRoutes = newValue; lock.unlock() } }
    /// True answers every upload with 500.
    var uploadFails: Bool { get { lock.lock(); defer { lock.unlock() }; return _uploadFails } set { lock.lock(); _uploadFails = newValue; lock.unlock() } }
    /// Seconds the mock waits before it answers an upload, to look at the app while a send is in flight.
    var uploadDelay: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return _uploadDelay } set { lock.lock(); _uploadDelay = newValue; lock.unlock() } }
    /// The bytes `GET /v1/chat/messages/:id/file` serves for a message id. A message without them gets the Mac's 404 for a missing file.
    func setChatImage(_ data: Data?, for id: String) { lock.lock(); _chatImages[id] = data; lock.unlock() }
    /// The folder the mock Mac's chat works in. `GET /v1/files/preview` answers for a path inside it, 404 when no file was set for it with
    /// `setFilePreview`, and 403 for any other path, with the Mac's own wording.
    static let previewRoot = "/Users/dev/demo-app"
    /// A file the preview route sends for `path`.
    func setFilePreview(_ data: Data, path: String, contentType: String = "text/plain; charset=utf-8", truncated: Bool = false) {
        lock.lock(); _previews[path] = (data, contentType, truncated); lock.unlock()
    }
    /// The paths the preview route was asked for, decoded.
    var previewRequests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requests.filter { $0.path == "/v1/files/preview" }.map { Self.previewPath($0.query) }
    }
    fileprivate static func previewPath(_ query: String) -> String {
        let value = query.split(separator: "&").first { $0.hasPrefix("path=") }.map { String($0.dropFirst(5)) } ?? ""
        return value.removingPercentEncoding ?? value
    }

    /// How many times the file route was asked for an image, to show that a screenshot is fetched once.
    var chatImageRequests: Int { lock.lock(); defer { lock.unlock() }; return _chatImageHits }
    /// The next sends answer 500 while this is true.
    var sendFails: Bool { get { lock.lock(); defer { lock.unlock() }; return _sendFails } set { lock.lock(); _sendFails = newValue; lock.unlock() } }
    /// How many of the next chat reads (the whole chat or one message) answer 503, as a Mac that is busy or out of reach does through a proxy. `Int.max` is an outage, and 0 ends it. A dropped
    /// connection is not used because URLSession sends a dropped GET again by itself.
    var chatReadFailures: Int { get { lock.lock(); defer { lock.unlock() }; return _chatReadFailures } set { lock.lock(); _chatReadFailures = newValue; lock.unlock() } }
    /// Seconds the Mac takes to answer a send after it has recorded the message.
    var sendDelay: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return _sendDelay } set { lock.lock(); _sendDelay = newValue; lock.unlock() } }
    /// Push the `chat.item` event before the answer to the send, as a fast socket can.
    var sendPushesFirst: Bool { get { lock.lock(); defer { lock.unlock() }; return _sendPushesFirst } set { lock.lock(); _sendPushesFirst = newValue; lock.unlock() } }
    /// True makes `streamChunk` send `chat.item` without the text, as a Mac before this change does.
    var legacyEvents: Bool { get { lock.lock(); defer { lock.unlock() }; return _legacyEvents } set { lock.lock(); _legacyEvents = newValue; lock.unlock() } }
    /// Seconds `GET /v1/chat/messages/:id` takes to answer, as a slow route to the Mac does.
    var messageReadDelay: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return _messageReadDelay } set { lock.lock(); _messageReadDelay = newValue; lock.unlock() } }
    /// The most single-message reads that were waiting for an answer at one time.
    var maxMessageReadsInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxReadsInFlight }
    /// How many times a single message was read with a GET.
    var messageReads: Int { lock.lock(); defer { lock.unlock() }; return _messageReads }
    /// The bytes of an upload by id.
    func uploaded(_ id: String) -> Data? { lock.lock(); defer { lock.unlock() }; return _uploads[id] }

    /// Appends `text` to an assistant item and sends `chat.item` for it, as one streamed chunk does on the Mac. Makes the item when it is new.
    func streamChunk(item id: String, _ text: String) {
        lock.lock()
        if let index = _chat.items.firstIndex(where: { $0.id == id }) { _chat.items[index].text = (_chat.items[index].text ?? "") + text }
        else { _chat.items.append(RemoteChatItem(id: id, kind: "assistant", date: Date(), text: text)) }
        _chat.running = true
        let inline = _legacyEvents ? nil : _chat.items.first { $0.id == id }
        lock.unlock()
        publish(RemoteEvent.chatItem, id: id, item: inline)
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
    func publish(_ kind: String, id: String? = nil, item: RemoteChatItem? = nil) -> Int {
        lock.lock()
        _seq += 1
        let event = RemoteEvent(seq: _seq, kind: kind, at: Date(), id: id, item: item)
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

    fileprivate func respond(_ connection: NWConnection, _ status: Int, _ body: Data) {
        let reason = [200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
                      413: "Content Too Large", 500: "Internal Server Error"][status] ?? "OK"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        connection.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    fileprivate func respond(_ connection: NWConnection, _ status: Int, _ body: Data, contentType: String, headers: [String: String] = [:]) {
        let extra = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        var out = Data("HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\n\(extra)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        connection.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    fileprivate func respond<T: Encodable>(_ connection: NWConnection, _ status: Int, _ value: T) {
        respond(connection, status, (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    fileprivate func fail(_ connection: NWConnection, _ status: Int, _ code: String, _ message: String) {
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
        if let status = brokenRoutes[request.path] {
            return status == 200 ? respond(connection, 200, Data(#"{"unexpected":true}"#.utf8)) : fail(connection, status, "failed", "the Mac could not answer")
        }
        let parts = request.path.split(separator: "/").map(String.init)
        if routeResources(request, parts, connection) || routeChat(request, parts, connection) || routePhaseFour(request, parts, connection) { return }
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
        if let raw = request.json["status"] as? String, let status = TaskStatus(rawValue: raw) {
            _tasks[index].status = status
            _tasks[index].closed = status == .done ? Date() : nil
        }
        if let name = request.json["waiting_on"] as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            _tasks[index].waitingOn = trimmed.isEmpty ? nil : trimmed
        }
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
            let name = (request.headers["x-file-name"] ?? "file").removingPercentEncoding ?? "file"
            let stored = "\(id.suffix(6))-\(name)"
            lock.lock(); _uploads[id] = request.body; _uploadNames[id] = stored; let delay = _uploadDelay; lock.unlock()
            let answer = RemoteUpload(id: id, fileName: name, storedName: stored, bytes: request.body.count)
            if delay > 0 { queue.asyncAfter(deadline: .now() + delay) { [self] in respond(connection, 201, answer) } } else { respond(connection, 201, answer) }
            return true
        }
        if parts.count == 3, parts[1] == "files", parts[2] == "preview", get {
            let path = Self.previewPath(request.query)
            lock.lock(); let file = _previews[path]; lock.unlock()
            if let file {
                respond(connection, 200, file.data, contentType: file.contentType, headers: file.truncated ? ["X-Ironpet-Truncated": "1"] : [:])
            } else if path.hasPrefix(Self.previewRoot + "/") {
                fail(connection, 404, "not_found", "there is no such file on the Mac")
            } else {
                fail(connection, 403, "forbidden", "the Mac only previews files inside the folders its chat works in")
            }
            return true
        }
        guard parts[1] == "chat" else { return false }
        if get, (parts.count == 3 && parts[2] == "current") || (parts.count == 4 && parts[2] == "messages") {
            lock.lock()
            let drop = _chatReadFailures > 0
            if drop, _chatReadFailures != Int.max { _chatReadFailures -= 1 }
            lock.unlock()
            if drop { fail(connection, 503, "unavailable", "the Mac could not answer"); return true }
        }
        switch (parts.count, parts.dropFirst(2).first ?? "") {
        case (3, "current") where get: respond(connection, 200, chat)
        case (4, "messages") where get:
            guard let item = chat.items.first(where: { $0.id == parts[3] }) else { fail(connection, 404, "not_found", "no message"); return true }
            lock.lock(); _messageReads += 1; _readsInFlight += 1; _maxReadsInFlight = max(_maxReadsInFlight, _readsInFlight); let delay = _messageReadDelay; lock.unlock()
            let answer = { [self] in
                lock.lock(); _readsInFlight -= 1; lock.unlock()
                respond(connection, 200, item)
            }
            if delay > 0 { queue.asyncAfter(deadline: .now() + delay, execute: answer) } else { answer() }
        case (3, "options") where request.method == "PATCH":
            // Only `mode` is acted on: it must be one the chat advertises, as on the Mac, and then it is the mode in force.
            guard let mode = request.json["mode"] as? String else { respond(connection, 200, Data("{\"changed\":true}".utf8)); return true }
            lock.lock(); let known = _chat.options.modes.contains { $0.id == mode }; if known { _chat.options.mode = mode }; lock.unlock()
            if known { respond(connection, 200, Data("{\"changed\":true}".utf8)) } else { fail(connection, 400, "invalid", "choose one of the modes the agent offers") }
        case (5, "messages") where get && parts[4] == "file":
            lock.lock(); let image = _chatImages[parts[3]]; _chatImageHits += 1; lock.unlock()
            guard let image else { fail(connection, 404, "not_found", "the file is no longer on the Mac"); return true }
            respond(connection, 200, image)
        case (3, "threads") where get: respond(connection, 200, ChatThreadListResponse(threads: chatThreads))
        case (4, "threads") where get:
            lock.lock(); let items = _threadItems[parts[3]]; lock.unlock()
            guard let thread = chatThreads.first(where: { $0.id == parts[3] }), let items else { fail(connection, 404, "not_found", "no thread"); return true }
            respond(connection, 200, RemoteChatThreadDetail(thread: thread, items: items))
        case (4, "current") where post && parts[3] == "messages":
            if sendFails { fail(connection, 500, "failed", "the Mac could not take the message"); return true }
            guard let text = request.json["text"] as? String, !text.isEmpty || request.json["upload_ids"] != nil else { fail(connection, 400, "invalid", "the message is empty"); return true }
            lock.lock()
            let queued = _chat.running
            let id = "m-\(_chat.items.count + 1)"
            if queued { _chat.queue.append(RemoteQueued(id: "q-\(id)", text: text)) }
            else {
                _chat.items.append(RemoteChatItem(id: id, kind: "user", date: Date(), origin: "ios", text: text)); _chat.running = true; _chat.state = "running"
                // The Mac records each upload as a screenshot item under the name it stored the file as.
                for (index, upload) in ((request.json["upload_ids"] as? [String]) ?? []).enumerated() {
                    guard let stored = _uploadNames[upload] else { continue }
                    _chat.items.append(RemoteChatItem(id: "\(id)-file-\(index)", kind: "screenshot", date: Date(), origin: "ios", fileName: stored, isImage: true))
                }
            }
            let delay = _sendDelay, pushFirst = _sendPushesFirst
            lock.unlock()
            let answer = { [self] in respond(connection, 200, RemoteSendResult(outcome: queued ? "queued" : "sent")) }
            let push = { [self] in _ = publish(queued ? RemoteEvent.chatState : RemoteEvent.chatItem, id: queued ? "queue" : id) }
            if pushFirst { push() }
            if delay > 0 { queue.asyncAfter(deadline: .now() + delay) { answer(); if !pushFirst { push() } } } else { answer(); if !pushFirst { push() } }
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


// MARK: Phase 4 routes

/// What the phase 4 mock serves. Change it through the properties on the server, then `publish` the event a real Mac would send.
struct MockPhaseFour {
    var automations: [RemoteAutomation] = MockIronPetServer.sampleAutomations
    var meetings: [RemoteMeeting] = MockIronPetServer.sampleMeetings
    var summaries: [String: String] = ["2026-11-14-1400": "## Summary\nPlanned the launch.\n"]
    var transcripts: [String: String] = ["2026-11-14-1400": "# Meeting\n[14:00:00] Me: hello secret-word\n", "2026-11-15-1000": "# Meeting\n[10:00:00] Me: second\n"]
    var meetingState = RemoteMeetingState()
    var config = RemoteConfig(pet: .init(name: "Ghost"), speech: .init(enabled: false, voice: "am_puck"), meetings: .init(enabled: true))
    var pets = [RemotePetChoice(id: "p-ghost", name: "Ghost", builtIn: true, selected: true), RemotePetChoice(id: "p-fox", name: "Fox", builtIn: false)]
    /// The screen scope. False answers every screen route with 403, like a Mac that has not granted it.
    var screenAllowed = true
    var screenStatus = RemoteScreenStatus(running: true, captureCount: 42, lastCapture: Date(timeIntervalSince1970: 1_700_000_000))
    var screenWindows: [RemoteScreenWindow] = MockIronPetServer.sampleScreenWindows
    var screenHits: [RemoteScreenHit] = MockIronPetServer.sampleScreenHits
    var usage = RemoteUsage(days: 7, rows: [.init(feature: "chat", model: "claude", requests: 12, totalTokens: 3400, cost: 0.42)], todayCost: 0.1, rangeCost: 0.42, hasCost: true)
}

extension MockIronPetServer {
    static let sampleAutomations: [RemoteAutomation] = [
        RemoteAutomation(id: "water", name: "Drink water", trigger: "every 45 minutes", triggerType: "interval", action: "bubble",
                         nextRun: Date(timeIntervalSince1970: 1_800_000_000), lastRun: RemoteAutomationRun(date: Date(timeIntervalSince1970: 1_700_000_000), outcome: "ok", output: "shown")),
        RemoteAutomation(id: "ci-watch", name: "CI watcher", enabled: true, trigger: "polls every 5 minutes", triggerType: "poll", action: "shell",
                         createdBy: "agent:ghost", approval: "pending", approvalDetail: "gh run list --limit 3"),
    ]

    static let sampleMeetings: [RemoteMeeting] = [
        RemoteMeeting(id: "2026-11-15-1000", date: Date(timeIntervalSince1970: 1_700_100_000), preview: "second", hasTranscript: true),
        RemoteMeeting(id: "2026-11-14-1400", date: Date(timeIntervalSince1970: 1_700_000_000), preview: "Planned the launch.", hasSummary: true, hasTranscript: true, hasAudio: true),
    ]

    static let sampleScreenWindows: [RemoteScreenWindow] = [
        RemoteScreenWindow(app: "Slack", window: "Ana (DM) - Acme", container: "Ana",
                           changes: ["2026-11-21T09:58+01:00 message | Can you review PR 4649? | c12 #a1b", "2026-11-21T10:02+01:00 message | Sure, after lunch | c13 #a1c"]),
        RemoteScreenWindow(app: "Safari", window: "Release notes", changes: ["2026-11-21T09:30+01:00 page | Release notes | c9"], url: "https://example.com/notes", more: 3),
    ]

    static let sampleScreenHits: [RemoteScreenHit] = [
        RemoteScreenHit(id: 12, time: Date(timeIntervalSince1970: 1_700_000_000), app: "Slack", bundleID: "com.tinyspeck.slackmacgap", window: "Ana (DM) - Acme",
                        snippet: "ship the release with key [redacted:openai-key] before standup"),
    ]

    var screenAllowed: Bool { get { lock.lock(); defer { lock.unlock() }; return _p4.screenAllowed } set { lock.lock(); _p4.screenAllowed = newValue; lock.unlock() } }
    var screenStatus: RemoteScreenStatus { get { lock.lock(); defer { lock.unlock() }; return _p4.screenStatus } set { lock.lock(); _p4.screenStatus = newValue; lock.unlock() } }
    var screenWindows: [RemoteScreenWindow] { get { lock.lock(); defer { lock.unlock() }; return _p4.screenWindows } set { lock.lock(); _p4.screenWindows = newValue; lock.unlock() } }

    var automations: [RemoteAutomation] { get { lock.lock(); defer { lock.unlock() }; return _p4.automations } set { lock.lock(); _p4.automations = newValue; lock.unlock() } }
    var meetings: [RemoteMeeting] { get { lock.lock(); defer { lock.unlock() }; return _p4.meetings } set { lock.lock(); _p4.meetings = newValue; lock.unlock() } }
    var meetingState: RemoteMeetingState { get { lock.lock(); defer { lock.unlock() }; return _p4.meetingState } set { lock.lock(); _p4.meetingState = newValue; lock.unlock() } }
    var config: RemoteConfig { get { lock.lock(); defer { lock.unlock() }; return _p4.config } set { lock.lock(); _p4.config = newValue; lock.unlock() } }

    fileprivate func routePhaseFour(_ request: Recorded, _ parts: [String], _ connection: NWConnection) -> Bool {
        guard parts.count >= 2, parts[0] == "v1" else { return false }
        switch parts[1] {
        case "automations": routeAutomations(request, parts, connection)
        case "meetings": routeMeetings(request, parts, connection)
        case "settings": routeSettings(request, parts, connection)
        case "screen": routeScreen(request, parts, connection)
        case "usage": lock.lock(); let usage = _p4.usage; lock.unlock(); respond(connection, 200, usage)
        default: return false
        }
        return true
    }

    private func routeAutomations(_ request: Recorded, _ parts: [String], _ connection: NWConnection) {
        let method = request.method
        if parts.count == 2 {
            if method == "GET" { lock.lock(); let list = _p4.automations; lock.unlock(); return respond(connection, 200, AutomationListResponse(automations: list)) }
            if method == "POST" {
                let json = request.json
                let name = json["name"] as? String ?? ""
                guard !name.isEmpty else { return fail(connection, 400, "invalid", "name is required") }
                let action = (json["action"] as? [String: Any])?["type"] as? String ?? "bubble"
                var item = RemoteAutomation(id: name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, action: action, createdBy: "remote:\(deviceID)")
                if action != "bubble" { item.approval = "pending" }
                lock.lock(); _p4.automations.append(item); lock.unlock()
                respond(connection, 201, item)
                publish(RemoteEvent.automationsChanged, id: item.id)
                if item.approval != nil { publish(RemoteEvent.automationNeedsApproval, id: item.id) }
                return
            }
        }
        if parts.count == 3, parts[2] == "request", method == "POST" { return respond(connection, 200, Data(#"{"outcome":"sent"}"#.utf8)) }
        guard parts.count >= 3 else { return fail(connection, 404, "not_found", "not found") }
        let id = parts[2]
        lock.lock()
        let index = _p4.automations.firstIndex { $0.id == id }
        lock.unlock()
        guard let index else { return fail(connection, 404, "not_found", "no automation with id \"\(id)\"") }
        if parts.count == 3 {
            switch method {
            case "GET": lock.lock(); var item = _p4.automations[index]; lock.unlock(); item.definition = "{\n  \"name\" : \"\(item.name)\"\n}"; respond(connection, 200, item)
            case "DELETE":
                lock.lock(); _p4.automations.remove(at: index); lock.unlock()
                respond(connection, 200, Data(#"{"deleted":"\#(id)"}"#.utf8))
                publish(RemoteEvent.automationsChanged, id: id)
            case "PATCH":
                lock.lock()
                if let name = request.json["name"] as? String { _p4.automations[index].name = name }
                let item = _p4.automations[index]
                lock.unlock()
                respond(connection, 200, item)
                publish(RemoteEvent.automationsChanged, id: id)
            default: fail(connection, 404, "not_found", "not found")
            }
            return
        }
        switch (method, parts[3]) {
        case ("GET", "history"): respond(connection, 200, AutomationHistoryResponse(history: [RemoteAutomationRun(date: Date(timeIntervalSince1970: 1_700_000_000), outcome: "ok", output: "shown")]))
        case ("GET", "log"):
            respond(connection, 200, AutomationLogResponse(log: [RemoteAutomationLogEntry(id: 1, automation: id, date: Date(timeIntervalSince1970: 1_700_000_000), outcome: "ok", summary: "shown")]))
        case ("POST", "pause"), ("POST", "resume"):
            lock.lock(); _p4.automations[index].enabled = parts[3] == "resume"; let item = _p4.automations[index]; lock.unlock()
            respond(connection, 200, item)
            publish(RemoteEvent.automationsChanged, id: id)
        case ("POST", "run-now"):
            lock.lock(); let waiting = _p4.automations[index].approval != nil; lock.unlock()
            respond(connection, 200, RemoteAutomationRunResult(id: id, status: waiting ? "waiting for approval" : "started"))
        default: fail(connection, 404, "not_found", "not found")
        }
    }

    private func routeMeetings(_ request: Recorded, _ parts: [String], _ connection: NWConnection) {
        let method = request.method
        if parts.count == 2, method == "GET" { lock.lock(); let list = _p4.meetings; lock.unlock(); return respond(connection, 200, MeetingListResponse(meetings: list)) }
        if parts.count == 3, method == "GET", parts[2] == "state" { lock.lock(); let state = _p4.meetingState; lock.unlock(); return respond(connection, 200, state) }
        if parts.count == 3, method == "POST", parts[2] == "stop" {
            lock.lock()
            let recording = _p4.meetingState.isRecording
            if recording { _p4.meetingState.phase = "summarizing" }
            lock.unlock()
            guard recording else { return fail(connection, 409, "conflict", "no meeting is being recorded") }
            respond(connection, 200, Data(#"{"stopped":true}"#.utf8))
            publish(RemoteEvent.meetingsChanged)
            return
        }
        guard parts.count >= 3 else { return fail(connection, 404, "not_found", "not found") }
        let id = parts[2]
        lock.lock(); let known = _p4.meetings.contains { $0.id == id }; lock.unlock()
        guard known else { return fail(connection, 404, "not_found", "no meeting with id \"\(id)\"") }
        if parts.count == 3, method == "DELETE" {
            lock.lock(); _p4.meetings.removeAll { $0.id == id }; lock.unlock()
            respond(connection, 200, Data(#"{"deleted":"\#(id)"}"#.utf8))
            publish(RemoteEvent.meetingsChanged)
            return
        }
        switch (method, parts.count == 4 ? parts[3] : "") {
        case ("GET", "summary"), ("GET", "transcript"):
            lock.lock(); let text = parts[3] == "summary" ? _p4.summaries[id] : _p4.transcripts[id]; lock.unlock()
            guard let text else { return fail(connection, 404, "not_found", "this meeting has no \(parts[3]) yet") }
            respond(connection, 200, RemoteMeetingText(id: id, text: text))
        case ("POST", "regenerate"): respond(connection, 202, Data(#"{"started":"\#(id)"}"#.utf8))
        case ("POST", "ask"): respond(connection, 200, Data(#"{"asked":"\#(id)"}"#.utf8))
        default: fail(connection, 404, "not_found", "not found")
        }
    }

    private func routeScreen(_ request: Recorded, _ parts: [String], _ connection: NWConnection) {
        lock.lock(); let state = _p4; lock.unlock()
        guard state.screenAllowed else { return fail(connection, 403, "forbidden", "This device may not read the screen. Turn on Screen text for it in Settings → Devices on the Mac.") }
        switch (request.method, parts.count > 2 ? parts[2] : "") {
        case ("GET", "status"): respond(connection, 200, state.screenStatus)
        case ("GET", "changes"): respond(connection, 200, RemoteScreenChanges(changes: state.screenWindows))
        case ("GET", "search"):
            // The mock has one hit and returns it for any non-empty query.
            let hits = request.query.contains("q=") ? state.screenHits : []
            respond(connection, 200, RemoteScreenSearch(count: hits.count, hits: hits))
        case ("GET", "captures") where parts.count == 4:
            guard let id = Int(parts[3]), id == 12 || id == 13 else { return fail(connection, 404, "not_found", "no capture \(parts[3]).") }
            respond(connection, 200, RemoteScreenCaptureResponse(capture: RemoteScreenCapture(
                id: id, time: Date(timeIntervalSince1970: 1_700_000_000), app: "Slack", window: "Ana (DM) - Acme", trigger: "click",
                outline: "Window\n  List (2)\n    Group [#a1b]: Can you review PR 4649?")))
        case ("POST", "pause"):
            lock.lock()
            _p4.screenStatus.paused = true
            _p4.screenStatus.pausedUntil = Date(timeIntervalSince1970: 1_700_000_900)
            let status = _p4.screenStatus
            lock.unlock()
            respond(connection, 200, status)
        default: fail(connection, 404, "not_found", "not found")
        }
    }

    private func routeSettings(_ request: Recorded, _ parts: [String], _ connection: NWConnection) {
        let method = request.method
        if parts.count == 2 {
            if method == "GET" { lock.lock(); let config = _p4.config; lock.unlock(); return respond(connection, 200, config) }
            if method == "PATCH" {
                let json = request.json
                lock.lock()
                var denied: String?
                if let reminders = json["reminders"] as? [String: Any], let paused = reminders["paused"] as? Bool { _p4.config.reminders.paused = paused }
                if let speech = json["speech"] as? [String: Any], let on = speech["enabled"] as? Bool { _p4.config.speech.enabled = on }
                // A background picked on the phone changes the Mac's config, so the pet resource every phone reads follows.
                if let chat = json["chat"] as? [String: Any], let background = chat["background"] as? String {
                    _p4.config.chat.background = background
                    _pet.background = background
                }
                if let meetings = json["meetings"] as? [String: Any] { if meetings["enabled"] as? Bool == false { _p4.config.meetings.enabled = false } else { denied = "meetings.enabled" } }
                if json["voice"] != nil { denied = "voice.baseUrl" }
                let config = _p4.config
                lock.unlock()
                if let denied { return fail(connection, 403, "forbidden", "\"\(denied)\" cannot be changed from the phone") }
                respond(connection, 200, config)
                publish(RemoteEvent.settingsChanged)
                return
            }
        }
        if parts.count == 3, parts[2] == "background", method == "POST" {
            // The Mac keeps the image as the custom background and tells every phone, this one included.
            let isImage = request.body.starts(with: [0xFF, 0xD8, 0xFF]) || request.body.starts(with: [0x89, 0x50, 0x4E, 0x47])
            guard isImage else { return fail(connection, 415, "unsupported_type", "the background must be a JPEG, PNG or HEIC image") }
            let hash = SHA256.hash(data: request.body).map { String(format: "%02x", $0) }.joined()
            lock.lock()
            _assetData[hash] = request.body
            _assets.removeAll { $0.id == "chat.background" }
            _assets.append(RemoteAsset(id: "chat.background", kind: "background", name: "custom.jpg", sha256: hash, bytes: request.body.count, contentType: "image/jpeg"))
            _p4.config.chat.background = "custom"
            _pet.background = "custom"
            _pet.backgroundAsset = "chat.background"
            let config = _p4.config
            lock.unlock()
            respond(connection, 200, config)
            publish(RemoteEvent.assetsChanged)
            publish(RemoteEvent.settingsChanged)
            return
        }
        if parts.count == 3, parts[2] == "pets", method == "GET" { lock.lock(); let pets = _p4.pets; lock.unlock(); return respond(connection, 200, PetChoiceListResponse(pets: pets)) }
        if parts.count == 3, parts[2] == "pet", method == "POST" {
            let id = request.json["id"] as? String
            lock.lock()
            let known = _p4.pets.contains { $0.id == id }
            if known { for index in _p4.pets.indices { _p4.pets[index].selected = _p4.pets[index].id == id } }
            lock.unlock()
            guard known else { return fail(connection, 404, "not_found", "no pet") }
            return respond(connection, 200, Data(#"{"selected":true}"#.utf8))
        }
        fail(connection, 404, "not_found", "not found")
    }
}
