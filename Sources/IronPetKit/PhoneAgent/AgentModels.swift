import Foundation

/// The API the phone's agent calls.
public enum AgentProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic, openai

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        }
    }

    /// The model a fresh install uses. Anthropic is the default provider, with the current Sonnet.
    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openai: return "gpt-5"
        }
    }
}

/// Provider, model and key. The key comes from the Keychain through `AgentKeyProviding`, and is never part of anything written to disk.
public struct AgentConfig: Equatable, Sendable {
    public var provider: AgentProvider
    public var model: String

    public init(provider: AgentProvider = .anthropic, model: String? = nil) {
        self.provider = provider
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.model = trimmed.isEmpty ? provider.defaultModel : trimmed
    }
}

/// Where the loop gets the API key. The app answers from the Keychain, so the loop never sees a store.
public protocol AgentKeyProviding: Sendable {
    func apiKey(for provider: AgentProvider) -> String?
}

/// One tool call the model made. `arguments` is the JSON object the model wrote, as text.
public struct AgentToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// The arguments as an object. A call whose arguments do not parse has none, and the tool answers with an error.
    public var object: [String: Any]? {
        let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

public struct AgentToolResult: Equatable, Sendable {
    public var callID: String
    public var name: String
    public var text: String
    public var isError: Bool

    public init(callID: String, name: String, text: String, isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.text = text
        self.isError = isError
    }
}

/// One step of the conversation, in the form both providers can be written from.
public enum AgentTurn: Equatable, Sendable {
    case user(String)
    case assistant(text: String, calls: [AgentToolCall])
    case toolResults([AgentToolResult])
}

/// What a provider's stream says, after the wire format is read.
public enum AgentStreamEvent: Equatable, Sendable {
    case text(String)
    case toolCall(AgentToolCall)
    case finished
}

/// What the loop reports while it runs, for a screen that shows the reply as it arrives.
public enum AgentLoopEvent: Equatable, Sendable {
    case text(String)
    case toolStarted(name: String)
    case toolFinished(AgentToolResult)
}

public struct AgentError: Error, Equatable, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
