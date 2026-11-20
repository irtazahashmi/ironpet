import Foundation

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

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "This device is no longer paired with the Mac."
        case .api(_, _, let message): return message
        case .pairingDenied: return "The Mac denied this device."
        case .pairingExpired: return "The pairing code expired. Make a new one on the Mac."
        case .invalidResponse: return "The Mac sent an answer this app does not understand."
        case .transport(let message): return message
        }
    }
}

/// The REST side of the remote API. One instance talks to one Mac with one token (none while pairing).
public final class IronPetClient: @unchecked Sendable {
    public let endpoint: ServerEndpoint
    public let token: String?
    let session: URLSession
    private let decoder = WireJSON.makeDecoder()
    private let encoder = WireJSON.makeEncoder()

    public init(endpoint: ServerEndpoint, token: String? = nil) {
        self.endpoint = endpoint
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        if endpoint.pinsCertificate, let pin = endpoint.pin {
            session = URLSession(configuration: configuration, delegate: PinnedSessionDelegate(pin: pin), delegateQueue: nil)
        } else {
            session = URLSession(configuration: configuration)
        }
    }

    deinit { session.finishTasksAndInvalidate() }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = base + path
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url ?? endpoint.baseURL
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw ClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, token != nil { throw ClientError.unauthorized }
            let detail = (try? decoder.decode(APIErrorBody.self, from: data))?.error
            throw ClientError.api(status: http.statusCode, code: detail?.code ?? "failed", message: detail?.message ?? "The Mac answered \(http.statusCode).")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) } catch { throw ClientError.invalidResponse }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        try decode(type, from: try await perform(request("GET", path, query: query)))
    }

    private func send<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, body: [String: String] = [:]) async throws -> T {
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

    public func task(id: String) async throws -> RemoteTaskDetail { try await get(RemoteTaskDetail.self, APIPath.task(id)) }

    public func suggestions() async throws -> [RemoteSuggestion] { try await get(SuggestionListResponse.self, APIPath.suggestions).suggestions }

    public func acceptSuggestion(id: String) async throws -> RemoteTask { try await send(RemoteTask.self, "POST", APIPath.acceptSuggestion(id)) }

    public func rejectSuggestion(id: String) async throws {
        _ = try await perform(request("POST", APIPath.rejectSuggestion(id), body: Data("{}".utf8)))
    }

    public func closeTask(id: String, note: String) async throws -> RemoteTask {
        try await send(RemoteTask.self, "POST", APIPath.closeTask(id), body: ["note": note])
    }

    public func addNote(id: String, note: String) async throws -> RemoteTask {
        try await send(RemoteTask.self, "PATCH", APIPath.task(id), body: ["note": note])
    }

    public func setStatus(id: String, status: TaskStatus, note: String) async throws -> RemoteTask {
        try await send(RemoteTask.self, "PATCH", APIPath.task(id), body: ["status": status.rawValue, "note": note])
    }
}
