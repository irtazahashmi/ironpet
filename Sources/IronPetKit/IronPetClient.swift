import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the Mac is and, for a self-signed `https` address, the certificate fingerprint to pin.
public struct ServerEndpoint: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var pin: String?

    public init(baseURL: URL, pin: String? = nil) { self.baseURL = baseURL; self.pin = pin }

    var pinsCertificate: Bool { pin != nil && baseURL.scheme?.lowercased() == "https" }
}

public enum ClientError: Error, Equatable, LocalizedError {
    /// A request with the device token got 401. The token is gone or revoked.
    case unauthorized
    case api(status: Int, code: String, message: String)
    case pairingDenied
    case pairingExpired
    case invalidResponse
    case transport(String)
    /// The Mac did not answer within the request timeout. It is a transport failure that a client may choose not to retry, because
    /// a read that timed out once makes the Mac build the same answer again.
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "This device is no longer paired with the Mac."
        case .api(_, _, let message): return message
        case .pairingDenied: return "The Mac denied this device."
        case .pairingExpired: return "The pairing code expired. Make a new one on the Mac."
        case .invalidResponse: return "The Mac sent an answer this app does not understand."
        // URLSession's own wording ("The request timed out.") is for the log, never for the person.
        case .transport, .timedOut: return "Can't reach your Mac."
        }
    }
}

/// The REST side of the remote API. One instance talks to one Mac with one token (none while pairing).
public final class IronPetClient: @unchecked Sendable {
    public let endpoint: ServerEndpoint
    public let token: String?
    let session: URLSession
    let decoder = WireJSON.makeDecoder()
    private let encoder = WireJSON.makeEncoder()

    public init(endpoint: ServerEndpoint, token: String? = nil) {
        self.endpoint = endpoint
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
#if canImport(Darwin)
        configuration.waitsForConnectivity = false
#endif
        // Nothing the Mac answers is kept, not even in memory: screen text must not sit in a cache.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
#if canImport(Security)
        if endpoint.pinsCertificate, let pin = endpoint.pin {
            session = URLSession(configuration: configuration, delegate: PinnedSessionDelegate(pin: pin), delegateQueue: nil)
        } else {
            session = URLSession(configuration: configuration)
        }
#else
        session = URLSession(configuration: configuration)
#endif
    }

    deinit { session.finishTasksAndInvalidate() }

    func url(_ path: String, query: [URLQueryItem] = [], encodedQuery: String? = nil) -> URL {
        var parts = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = base + path
        parts.queryItems = query.isEmpty ? nil : query
        if let encodedQuery { parts.percentEncodedQuery = encodedQuery }
        return parts.url ?? endpoint.baseURL
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], encodedQuery: String? = nil, body: Data? = nil, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(path, query: query, encodedQuery: encodedQuery))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    func perform(_ request: URLRequest) async throws -> Data { try await performWithResponse(request).data }

    func performWithResponse(_ request: URLRequest, acceptNotModified: Bool = false) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            // A request the app cancelled is not a transport failure. Only the calling task's own cancellation counts: URLSession also
            // reports a rejected certificate pin as `.cancelled`, and that must stay a visible transport error.
            if error is CancellationError || ((error as? URLError)?.code == .cancelled && Task.isCancelled) { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { throw ClientError.timedOut }
            throw ClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        // 304 is an answer, not a failure, for a read that sent the ETag it saved.
        guard (200..<300).contains(http.statusCode) || (acceptNotModified && http.statusCode == 304) else {
            if http.statusCode == 401, token != nil { throw ClientError.unauthorized }
            let detail = (try? decoder.decode(APIErrorBody.self, from: data))?.error
            throw ClientError.api(status: http.statusCode, code: detail?.code ?? "failed", message: detail?.message ?? "The Mac answered \(http.statusCode).")
        }
        return (data, http)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) } catch { throw ClientError.invalidResponse }
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        try decode(type, from: try await perform(request("GET", path, query: query)))
    }

    private func send<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, body: [String: String] = [:]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try decode(type, from: try await perform(request(method, path, body: data)))
    }

    private func sendJSON<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try decode(type, from: try await perform(request(method, path, body: data)))
    }

    // MARK: Pairing

    public func pair(_ body: PairRequest) async throws -> PairAccepted {
        let data = try encoder.encode(body)
        return try decode(PairAccepted.self, from: try await perform(request("POST", APIPath.pair, body: data)))
    }

    public func pollPairing(id: String, secret: String) async throws -> PairPoll {
        try decode(PairPoll.self, from: try await perform(request("GET", APIPath.pairStatus(id), headers: ["X-Pairing-Secret": secret])))
    }

    // MARK: Device

    public func device() async throws -> RemoteDevice { try await get(RemoteDevice.self, APIPath.deviceMe) }

    /// Unpairs this device on the Mac.
    public func revokeSelf() async throws { _ = try await perform(request("DELETE", APIPath.deviceMe)) }

    // MARK: Tasks and suggestions

    public func tasks(includeDone: Bool = true) async throws -> [RemoteTask] {
        try await get(TaskListResponse.self, APIPath.tasks, query: includeDone ? [URLQueryItem(name: "include_done", value: "1")] : []).tasks
    }

    public func taskFilters() async throws -> [QuickFilter] { try await get(QuickFilterListResponse.self, APIPath.taskFilters).filters }

    public func deleteTaskFilter(id: String) async throws { _ = try await perform(request("DELETE", APIPath.taskFilter(id))) }

    public func task(id: String) async throws -> RemoteTaskDetail { try await get(RemoteTaskDetail.self, APIPath.task(id)) }

    public func suggestions() async throws -> [RemoteSuggestion] { try await get(SuggestionListResponse.self, APIPath.suggestions).suggestions }

    public func acceptSuggestion(id: String) async throws -> RemoteTask { try await send(RemoteTask.self, "POST", APIPath.acceptSuggestion(id)) }

    public func rejectSuggestion(id: String) async throws {
        _ = try await perform(request("POST", APIPath.rejectSuggestion(id), body: Data("{}".utf8)))
    }

    /// The three change calls take the phone's `clientID` for the change and `baseUpdated`, the `updated` time of the copy it edited.
    /// The Mac applies a `clientID` once, and answers 409 when the task changed after `baseUpdated`. An older Mac ignores both.
    public func closeTask(id: String, note: String, clientID: String? = nil, baseUpdated: Date? = nil) async throws -> RemoteTask {
        try await sendJSON(RemoteTask.self, "POST", APIPath.closeTask(id), body: change(["note": note], clientID, baseUpdated))
    }

    public func addNote(id: String, note: String) async throws -> RemoteTask {
        try await send(RemoteTask.self, "PATCH", APIPath.task(id), body: ["note": note])
    }

    public func setStatus(id: String, status: TaskStatus, note: String, clientID: String? = nil, baseUpdated: Date? = nil) async throws -> RemoteTask {
        try await sendJSON(RemoteTask.self, "PATCH", APIPath.task(id), body: change(["status": status.rawValue, "note": note], clientID, baseUpdated))
    }

    /// Changes the title, the notes, or both. A nil field stays as it is.
    public func editTask(id: String, title: String?, notes: String?, clientID: String? = nil, baseUpdated: Date? = nil) async throws -> RemoteTask {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let notes { body["notes"] = notes }
        return try await sendJSON(RemoteTask.self, "PATCH", APIPath.task(id), body: change(body, clientID, baseUpdated))
    }

    public func createTask(title: String, notes: String = "", status: TaskStatus = .backlog, clientID: String? = nil) async throws -> RemoteTask {
        try await sendJSON(RemoteTask.self, "POST", APIPath.tasks, body: change(["title": title, "notes": notes, "status": status.rawValue], clientID, nil))
    }

    private func change(_ fields: [String: Any], _ clientID: String?, _ baseUpdated: Date?) -> [String: Any] {
        var body = fields
        if let clientID { body["client_id"] = clientID }
        if let baseUpdated { body["base_updated"] = ISO8601DateFormatter().string(from: baseUpdated) }
        return body
    }

    /// Names who holds the task, or clears that with a nil or blank `name`. A `status` in the same call changes it in the same update.
    /// The Mac has taken `waiting_on` on `PATCH /v1/tasks/:id` since the route was added, so an older Mac accepts this too.
    public func setWaitingOn(id: String, name: String?, status: TaskStatus? = nil, note: String = "") async throws -> RemoteTask {
        var body = ["waiting_on": name ?? ""]
        if let status { body["status"] = status.rawValue }
        if !note.isEmpty { body["note"] = note }
        return try await send(RemoteTask.self, "PATCH", APIPath.task(id), body: body)
    }

    // MARK: Pet, bubbles, agents, alerts, today

    public func pet() async throws -> RemotePet { try await get(RemotePet.self, APIPath.pet) }

    public func perform(trick: String) async throws { _ = try await perform(request("POST", APIPath.trick(trick), body: Data("{}".utf8))) }

    public func bubbles() async throws -> [RemoteBubble] { try await get(BubbleListResponse.self, APIPath.bubbles).bubbles }

    public func press(bubble: String, action: String) async throws {
        _ = try await perform(request("POST", APIPath.bubbleAction(bubble, action), body: Data("{}".utf8)))
    }

    public func agents() async throws -> [RemoteAgent] { try await get(AgentListResponse.self, APIPath.agents).agents }

    public func agent(id: String) async throws -> RemoteAgent { try await get(RemoteAgent.self, APIPath.agent(id)) }

    public func acknowledgeAgent(id: String) async throws { _ = try await perform(request("POST", APIPath.acknowledgeAgent(id), body: Data("{}".utf8))) }

    public func askAboutAgent(id: String) async throws { _ = try await perform(request("POST", APIPath.askAboutAgent(id), body: Data("{}".utf8))) }

    public func alerts() async throws -> [RemoteAlert] { try await get(AlertListResponse.self, APIPath.alerts).alerts }

    /// The record a public id in chat names, with its fields when the Mac can read its kind.
    public func record(_ id: String) async throws -> RecordDetails {
        let data = try await perform(request("GET", APIPath.record(id)))
        do { return try RecordDetails(json: data) } catch { throw ClientError.invalidResponse }
    }

    public func dismissAlert(id: String) async throws { _ = try await perform(request("POST", APIPath.dismissAlert(id), body: Data("{}".utf8))) }

    public func dismissAllAlerts() async throws { _ = try await perform(request("POST", APIPath.dismissAllAlerts, body: Data("{}".utf8))) }

    public func askAboutAlert(id: String) async throws { _ = try await perform(request("POST", APIPath.askAboutAlert(id), body: Data("{}".utf8))) }

    public func today(kind: String) async throws -> RemoteToday {
        try await get(RemoteToday.self, APIPath.today, query: [URLQueryItem(name: "kind", value: kind)])
    }

    // MARK: Assets

    public func assetManifest() async throws -> [RemoteAsset] { try await get(AssetManifestResponse.self, APIPath.assetManifest).assets }

    public func downloadAsset(sha256: String) async throws -> Data { try await perform(request("GET", APIPath.asset(sha256))) }

    /// The image behind a `screenshot` message of the open chat. It throws the Mac's reason, such as "the file is no longer on the Mac".
    public func downloadChatImage(messageID: String, agentId: String? = nil) async throws -> Data {
        try await perform(request("GET", APIPath.chatMessageFile(messageID), query: Self.agentQuery(agentId)))
    }

    /// A file a reply named, from the folder the Mac chat works in: the start of a text file, or an image. It throws the Mac's reason,
    /// such as "the Mac only previews files inside the folders its chat works in".
    public func filePreview(path: String) async throws -> RemoteFilePreview {
        // Every character but the unreserved ones is escaped, so a `+` or `&` in a file name reaches the Mac as it is.
        let value = path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")) ?? path
        let (data, response) = try await performWithResponse(request("GET", APIPath.filePreview, encodedQuery: "path=" + value))
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return RemoteFilePreview(path: path, contentType: type, data: data, truncated: response.value(forHTTPHeaderField: "X-Ironpet-Truncated") == "1")
    }

    // MARK: Chat

    func post<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [], json: [String: Any] = [:]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try decode(type, from: try await perform(request("POST", path, query: query, body: data)))
    }

    func post(_ path: String, query: [URLQueryItem] = [], json: [String: Any] = [:]) async throws {
        _ = try await perform(request("POST", path, query: query, body: try JSONSerialization.data(withJSONObject: json)))
    }

    /// The `agentId` query item of a chat call. Nil, and the empty id, add nothing, so the call is agent 1's and an older Mac sees the
    /// request it always saw.
    static func agentQuery(_ agentId: String?) -> [URLQueryItem] {
        guard let agentId, !agentId.isEmpty else { return [] }
        return [URLQueryItem(name: "agentId", value: agentId)]
    }

    /// The chat. With `limit`, the newest `limit` messages, or the ones before `before`; `hasMore` says whether older ones exist. A Mac
    /// older than paging ignores the query and sends the whole thread, with `hasMore` nil.
    /// The chat, unless it is still the one the phone saved. `etag` is the ETag of that saved chat. The answer is `.notModified` when the
    /// Mac says nothing changed, or the chat with the ETag to save next time.
    public func chatIfChanged(etag: String?, limit: Int? = nil, before: String? = nil, after: Int? = nil, epoch: String? = nil, agentId: String? = nil) async throws -> ChatRead {
        var query = Self.agentQuery(agentId)
        // The cursor of the last answer: the Mac sends only the messages that changed since. An older Mac ignores both.
        if let after, let epoch {
            query.append(URLQueryItem(name: "after", value: String(after)))
            query.append(URLQueryItem(name: "epoch", value: epoch))
        }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        var headers: [String: String] = [:]
        if let etag { headers["If-None-Match"] = etag }
        var urlRequest = request("GET", APIPath.chat, query: query, headers: headers)
        // URLSession's own cache would turn a 304 back into the cached 200, so the answer would not be the Mac's.
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await performWithResponse(urlRequest, acceptNotModified: true)
        if http.statusCode == 304 { return .notModified }
        return .snapshot(try decode(RemoteChatSnapshot.self, from: data), etag: http.value(forHTTPHeaderField: "ETag"))
    }

    public func chat(limit: Int? = nil, before: String? = nil, agentId: String? = nil) async throws -> RemoteChatSnapshot {
        var query = Self.agentQuery(agentId)
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        return try await get(RemoteChatSnapshot.self, APIPath.chat, query: query)
    }

    public func chatMessage(id: String, agentId: String? = nil) async throws -> RemoteChatItem {
        try await get(RemoteChatItem.self, APIPath.chatMessage(id), query: Self.agentQuery(agentId))
    }

    public func chatThreads(agentId: String? = nil) async throws -> [RemoteChatThread] {
        try await get(ChatThreadListResponse.self, APIPath.chatThreads, query: Self.agentQuery(agentId)).threads
    }

    public func chatThread(id: String, agentId: String? = nil) async throws -> RemoteChatThreadDetail {
        try await get(RemoteChatThreadDetail.self, APIPath.chatThread(id), query: Self.agentQuery(agentId))
    }

    /// The agents of the Mac, enabled or not, in the order the Mac lists them (agent 1 first). A Mac from before several agents has no
    /// such route and answers 404, so the caller treats a failure as "agent 1 only".
    public func agentRecords() async throws -> [RemoteAgentRecord] { try await get(AgentRecordListResponse.self, APIPath.agentRecords).agents }

    /// Sends a message into the chat the Mac has open. `uploadIDs` come from `upload`. `clientID` is a UUID the phone made for this message.
    @discardableResult
    public func sendMessage(text: String, uploadIDs: [String] = [], reply: RemoteReplyRef? = nil, clientID: String? = nil, agentId: String? = nil) async throws -> RemoteSendResult {
        var body: [String: Any] = ["text": text]
        // The Mac dedupes on the client id, so a send that is repeated over HTTPS after the socket lost its ack creates one message.
        if let clientID { body["client_id"] = clientID }
        if !uploadIDs.isEmpty { body["upload_ids"] = uploadIDs }
        if let reply {
            var quote: [String: Any] = ["item_id": reply.itemID]
            if let selection = reply.selectionText { quote["selection_text"] = selection }
            body["reply"] = quote
        }
        return try await post(RemoteSendResult.self, APIPath.chatSend, query: Self.agentQuery(agentId), json: body)
    }

    public func stopChat(agentId: String? = nil) async throws { try await post(APIPath.chatStop, query: Self.agentQuery(agentId)) }

    /// Makes a saved thread the Mac's open chat. The Mac answers 409 while a turn runs or a question waits.
    public func openThread(id: String, agentId: String? = nil) async throws { try await post(APIPath.chatOpen(id), query: Self.agentQuery(agentId)) }

    public func newChat(agentId: String? = nil) async throws { try await post(APIPath.chatNew, query: Self.agentQuery(agentId)) }

    /// Changes the chat's agent, model, folder or permission mode. The Mac answers 409 while a turn runs, for all but `mode`.
    public func setChatOptions(_ change: RemoteChatOptionsChange, agentId: String? = nil) async throws {
        _ = try await perform(request("PATCH", APIPath.chatOptions, query: Self.agentQuery(agentId), body: try JSONSerialization.data(withJSONObject: change.json)))
    }

    public func decide(approval id: String, allow: Bool, agentId: String? = nil) async throws {
        try await post(APIPath.chatApproval(id), query: Self.agentQuery(agentId), json: ["allow": allow])
    }

    public func answer(form id: String, answers: [String: RemoteFormAnswer], agentId: String? = nil) async throws {
        try await post(APIPath.chatForm(id), query: Self.agentQuery(agentId), json: ["answers": Self.json(answers)])
    }

    public func submit(form id: String, answers: [String: RemoteFormAnswer] = [:], agentId: String? = nil) async throws {
        try await post(APIPath.chatFormSubmit(id), query: Self.agentQuery(agentId), json: ["answers": Self.json(answers)])
    }

    public func skip(form id: String, agentId: String? = nil) async throws { try await post(APIPath.chatFormSkip(id), query: Self.agentQuery(agentId)) }

    private static func json(_ answers: [String: RemoteFormAnswer]) -> [String: Any] {
        answers.mapValues { answer -> Any in
            switch answer {
            case .text(let text): return text
            case .list(let list): return list
            case .flag(let flag): return flag
            }
        }
    }

    /// Uploads one photo or file, up to 20 MiB, as the raw body. The answer's id goes into `sendMessage`.
    public func upload(_ data: Data, fileName: String, contentType: String) async throws -> RemoteUpload {
        var request = request("POST", APIPath.uploads, body: data, headers: ["Content-Type": contentType,
                                                                              "X-File-Name": fileName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"])
        request.timeoutInterval = 120
        return try decode(RemoteUpload.self, from: try await perform(request))
    }
}
