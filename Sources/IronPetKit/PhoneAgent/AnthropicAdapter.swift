import Foundation

/// The Anthropic Messages API with streaming: `POST /v1/messages` with `stream: true`.
public struct AnthropicAdapter: AgentProviderAdapter {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let version = "2023-06-01"
    public static let maxTokens = 4096

    public init() {}

    public func request(system: String, turns: [AgentTurn], tools: [any AgentTool], config: AgentConfig, apiKey: String) throws -> AgentHTTPRequest {
        var messages: [[String: Any]] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                messages.append(["role": "user", "content": [["type": "text", "text": text]]])
            case .assistant(let text, let calls):
                var blocks: [[String: Any]] = []
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for call in calls {
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": call.object ?? [:]])
                }
                if !blocks.isEmpty { messages.append(["role": "assistant", "content": blocks]) }
            case .toolResults(let results):
                let blocks: [[String: Any]] = results.map {
                    var block: [String: Any] = ["type": "tool_result", "tool_use_id": $0.callID, "content": $0.text]
                    if $0.isError { block["is_error"] = true }
                    return block
                }
                messages.append(["role": "user", "content": blocks])
            }
        }
        var body: [String: Any] = ["model": config.model, "max_tokens": Self.maxTokens, "stream": true, "system": system, "messages": messages]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.detail, "input_schema": AgentJSON.object($0.schema).any] }
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return AgentHTTPRequest(url: Self.endpoint, headers: ["x-api-key": apiKey, "anthropic-version": Self.version,
                                                              "content-type": "application/json", "accept": "text/event-stream"], body: data)
    }

    public func makeReader() -> any AgentStreamReading { Reader() }

    private final class Reader: AgentStreamReading {
        /// A tool call being written: its id, name and the pieces of its arguments, by content block index.
        private var calls: [Int: (id: String, name: String, json: String)] = [:]

        func read(_ event: SSEEvent) throws -> [AgentStreamEvent] {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(event.data.utf8))) as? [String: Any] else { return [] }
            let type = (object["type"] as? String) ?? event.name ?? ""
            switch type {
            case "content_block_start":
                guard let index = object["index"] as? Int, let block = object["content_block"] as? [String: Any],
                      block["type"] as? String == "tool_use" else { return [] }
                calls[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
                return []
            case "content_block_delta":
                guard let index = object["index"] as? Int, let delta = object["delta"] as? [String: Any] else { return [] }
                switch delta["type"] as? String {
                case "text_delta": return (delta["text"] as? String).map { [.text($0)] } ?? []
                case "input_json_delta": calls[index]?.json += delta["partial_json"] as? String ?? ""; return []
                default: return []
                }
            case "content_block_stop":
                guard let index = object["index"] as? Int, let call = calls.removeValue(forKey: index) else { return [] }
                return [.toolCall(AgentToolCall(id: call.id, name: call.name, arguments: call.json))]
            case "message_stop":
                return [.finished]
            case "error":
                let message = (object["error"] as? [String: Any])?["message"] as? String
                throw AgentError(message ?? "Anthropic returned an error")
            default:
                return []
            }
        }
    }
}
