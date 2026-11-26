import Foundation

/// The OpenAI Responses API with streaming: `POST /v1/responses` with `stream: true`. Nothing is stored on OpenAI's side (`store: false`),
/// so each request carries the whole conversation.
public struct OpenAIAdapter: AgentProviderAdapter {
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public init() {}

    public func request(system: String, turns: [AgentTurn], tools: [any AgentTool], config: AgentConfig, apiKey: String) throws -> AgentHTTPRequest {
        var input: [[String: Any]] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                input.append(["role": "user", "content": text])
            case .assistant(let text, let calls):
                if !text.isEmpty { input.append(["role": "assistant", "content": text]) }
                for call in calls {
                    input.append(["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments])
                }
            case .toolResults(let results):
                for result in results { input.append(["type": "function_call_output", "call_id": result.callID, "output": result.text]) }
            }
        }
        var body: [String: Any] = ["model": config.model, "instructions": system, "input": input, "stream": true, "store": false]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "name": $0.name, "description": $0.detail, "parameters": AgentJSON.object($0.schema).any] }
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return AgentHTTPRequest(url: Self.endpoint, headers: ["authorization": "Bearer \(apiKey)", "content-type": "application/json",
                                                              "accept": "text/event-stream"], body: data)
    }

    public func makeReader() -> any AgentStreamReading { Reader() }

    private final class Reader: AgentStreamReading {
        func read(_ event: SSEEvent) throws -> [AgentStreamEvent] {
            guard event.data != "[DONE]",
                  let object = (try? JSONSerialization.jsonObject(with: Data(event.data.utf8))) as? [String: Any] else { return [] }
            switch (object["type"] as? String) ?? event.name ?? "" {
            case "response.output_text.delta":
                return (object["delta"] as? String).map { [.text($0)] } ?? []
            case "response.output_item.done":
                // The finished item has the whole call, so the pieces of its arguments do not need joining.
                guard let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" else { return [] }
                let id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? ""
                return [.toolCall(AgentToolCall(id: id, name: item["name"] as? String ?? "", arguments: item["arguments"] as? String ?? ""))]
            case "response.completed", "response.incomplete":
                return [.finished]
            case "response.failed", "error":
                let error = (object["error"] as? [String: Any]) ?? ((object["response"] as? [String: Any])?["error"] as? [String: Any])
                throw AgentError((error?["message"] as? String) ?? (object["message"] as? String) ?? "OpenAI returned an error")
            default:
                return []
            }
        }
    }
}
