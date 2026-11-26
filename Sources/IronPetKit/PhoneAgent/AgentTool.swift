import Foundation

/// A tool the model may call. `schema` is the JSON Schema of its arguments, as a JSON object.
public protocol AgentTool: Sendable {
    var name: String { get }
    var detail: String { get }
    var schema: [String: AgentJSON] { get }
    /// Runs the tool. A thrown error goes back to the model as the tool's result, so it can tell the user or try another way.
    func run(_ arguments: [String: Any]) async throws -> String
}

/// A JSON value that is `Sendable`, for tool schemas.
public enum AgentJSON: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([AgentJSON])
    case object([String: AgentJSON])

    public var any: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .number(let value): return value
        case .array(let values): return values.map(\.any)
        case .object(let values): return values.mapValues(\.any)
        }
    }
}

extension AgentTool {
    /// `{type: object, properties, required}` for one tool, from the properties and the names that are required.
    public static func objectSchema(_ properties: [String: AgentJSON], required: [String] = []) -> [String: AgentJSON] {
        ["type": .string("object"), "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    public static func property(_ type: String, _ detail: String) -> AgentJSON {
        .object(["type": .string(type), "description": .string(detail)])
    }
}

/// A small reader for the arguments a model wrote.
public enum AgentArguments {
    public static func string(_ arguments: [String: Any], _ key: String) -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        let text = (value as? String) ?? "\(value)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func required(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = string(arguments, key) else { throw AgentError("\(key) is required") }
        return value
    }
}
