import Foundation

/// The JSON-RPC 2.0 envelope every ironpet client uses (docs/protocol.md). The types carry no ironpet method: `params` and
/// `result` are any JSON value, and a transport (stdio, HTTP, WebSocket) only moves these values.
public enum JSONRPC {
    public static let version = "2.0"
}

/// The id a client chooses for a request. A response repeats it. It is `null` only in an error for a request that could not be read.
public enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case int(Int)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Int.self) { self = .int(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be a string, a number or null") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
}

/// A call from a client. The server answers it with one `JSONRPCResponse` that has the same `id`.
public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public init(id: JSONRPCID, method: String, params: RemoteJSON? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var jsonrpc = JSONRPC.version
    public var id: JSONRPCID
    public var method: String
    public var params: RemoteJSON?
}

/// A message that expects no answer. The server sends one for each `APIEvent`.
public struct JSONRPCNotification: Codable, Equatable, Sendable {
    public init(method: String, params: RemoteJSON? = nil) {
        self.method = method
        self.params = params
    }

    public var jsonrpc = JSONRPC.version
    public var method: String
    public var params: RemoteJSON?
}

/// The `error` member of a failed response.
public struct JSONRPCError: Codable, Equatable, Sendable, Error {
    public init(code: Int, message: String, data: RemoteJSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var code: Int
    public var message: String
    public var data: RemoteJSON?

    /// The codes JSON-RPC 2.0 reserves.
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}

/// The answer to one request: `result` when it worked, `error` when it did not, never both.
public struct JSONRPCResponse: Codable, Equatable, Sendable {
    public init(id: JSONRPCID, result: RemoteJSON) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCID, error: JSONRPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }

    public var jsonrpc = JSONRPC.version
    public var id: JSONRPCID
    public var result: RemoteJSON?
    public var error: JSONRPCError?

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        id = try c.decode(JSONRPCID.self, forKey: .id)
        error = try c.decodeIfPresent(JSONRPCError.self, forKey: .error)
        // `"result": null` is a valid success for a call that returns nothing, so it stays distinct from a missing member.
        result = c.contains(.result) ? try c.decode(RemoteJSON.self, forKey: .result) : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        if let error { try c.encode(error, forKey: .error) } else { try c.encode(result ?? .null, forKey: .result) }
    }
}
