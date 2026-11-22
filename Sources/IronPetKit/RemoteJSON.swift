import Foundation

/// Any JSON value. A task's `source_ref` is whatever the agent that made it recorded, so the wire type cannot name its fields.
public enum RemoteJSON: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([RemoteJSON])
    case object([String: RemoteJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int.self) { self = .int(value) }
        else if let value = try? c.decode(Double.self) { self = .double(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([RemoteJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: RemoteJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .int(let value): try c.encode(value)
        case .double(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    /// The reference a task keeps as text: a JSON object or array becomes that value, anything else stays a string.
    public init(reference text: String) {
        let first = text.drop { $0.isWhitespace }.first
        if first == "{" || first == "[", let value = try? JSONDecoder().decode(RemoteJSON.self, from: Data(text.utf8)) {
            self = value
        } else {
            self = .string(text)
        }
    }
}
