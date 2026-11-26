import Foundation

/// The chat tool agents see (served by `MCPEndpoint` at `POST /mcp`). It only reads, through `ChatAPI`.
@MainActor
package enum ChatMCP {
    package static let names: Set<String> = ["chat_threads_list"]

    package static var tools: [[String: Any]] {
        [["name": "chat_threads_list",
          "description": "List an agent's saved chat threads, newest first: id, title, folder, update time and owner. Defaults to the calling agent's threads.",
          "inputSchema": ["type": "object",
                          "properties": ["agentId": ["type": "string", "description": "The agent whose threads to list, such as agent_default for agent 1. Defaults to the calling agent."]],
                          "required": [String]()]]]
    }

    /// `agent` is the agent the call comes from, used when the arguments name none.
    package static func call(_ name: String, _ arguments: [String: Any], api: ChatAPI, agent: String?) async -> Result<Any, AutomationError> {
        switch name {
        case "chat_threads_list":
            do {
                let threads = try await api.threads(agentId: arguments["agentId"] as? String ?? agent)
                return .success(["threads": threads.map(json)])
            } catch {
                return .failure(.init(message: (error as? APIError)?.message ?? error.localizedDescription))
            }
        default:
            return .failure(.init(message: "unknown chat tool \(name)"))
        }
    }

    private static func json(_ thread: ChatThreadInfo) -> [String: Any] {
        var object: [String: Any] = ["id": thread.id, "title": thread.title, "workspace": thread.workspace, "agentId": AgentOwner.id(thread.agentId),
                                     "updatedAt": ISO8601DateFormatter().string(from: thread.updatedAt)]
        if let automation = thread.automation { object["automation"] = automation }
        if let ref = thread.ref { object["ref"] = ref }
        return object
    }
}
