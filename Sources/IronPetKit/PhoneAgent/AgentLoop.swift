import Foundation

/// The agent loop: ask the model, run the tools it calls, send the results back, and repeat until it answers without a call. It depends
/// on Foundation only. The app supplies the transport, the key and the tools.
public final class AgentLoop: Sendable {
    /// The most rounds of model and tools in one request, so a model that keeps calling tools cannot run forever.
    public static let maxRounds = 8

    private let transport: any AgentTransport
    private let keys: any AgentKeyProviding
    private let tools: [any AgentTool]
    private let system: String

    public init(transport: any AgentTransport, keys: any AgentKeyProviding, tools: [any AgentTool], system: String) {
        self.transport = transport
        self.keys = keys
        self.tools = tools
        self.system = system
    }

    public static func adapter(for provider: AgentProvider) -> any AgentProviderAdapter {
        switch provider {
        case .anthropic: return AnthropicAdapter()
        case .openai: return OpenAIAdapter()
        }
    }

    /// Runs one user message over `history` and returns the turns it added, the user's message first. `onEvent` hears the text as it
    /// streams and each tool as it starts and finishes.
    public func run(_ message: String, history: [AgentTurn], config: AgentConfig,
                    onEvent: @Sendable (AgentLoopEvent) -> Void = { _ in }) async throws -> [AgentTurn] {
        guard let key = keys.apiKey(for: config.provider), !key.isEmpty else {
            throw AgentError("Add your \(config.provider.label) API key in Settings first.")
        }
        let adapter = Self.adapter(for: config.provider)
        var added: [AgentTurn] = [.user(message)]
        for _ in 0..<Self.maxRounds {
            try Task.checkCancellation()
            let request = try adapter.request(system: system, turns: history + added, tools: tools, config: config, apiKey: key)
            var text = ""
            var calls: [AgentToolCall] = []
            let events = AgentStreamReader.events(lines: transport.lines(for: request), adapter: adapter)
            for try await event in events {
                switch event {
                case .text(let piece): text += piece; onEvent(.text(piece))
                case .toolCall(let call): calls.append(call)
                case .finished: break
                }
            }
            added.append(.assistant(text: text, calls: calls))
            guard !calls.isEmpty else { return added }
            var results: [AgentToolResult] = []
            for call in calls {
                onEvent(.toolStarted(name: call.name))
                let result = await execute(call)
                results.append(result)
                onEvent(.toolFinished(result))
            }
            added.append(.toolResults(results))
        }
        added.append(.assistant(text: "I stopped after \(Self.maxRounds) steps without an answer. Ask again, or ask for less.", calls: []))
        return added
    }

    private func execute(_ call: AgentToolCall) async -> AgentToolResult {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return AgentToolResult(callID: call.id, name: call.name, text: "There is no tool named \(call.name).", isError: true)
        }
        guard let arguments = call.object else {
            return AgentToolResult(callID: call.id, name: call.name, text: "The arguments are not a JSON object.", isError: true)
        }
        do {
            return AgentToolResult(callID: call.id, name: call.name, text: try await tool.run(arguments))
        } catch {
            return AgentToolResult(callID: call.id, name: call.name, text: (error as? AgentError)?.message ?? error.localizedDescription, isError: true)
        }
    }
}
