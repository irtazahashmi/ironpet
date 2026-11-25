import Foundation

/// The agent record tools agents see (served by `MCPEndpoint` at `POST /mcp`). Both only read, through `AgentRecordsAPI`.
/// `agents_list` is about agent records, not the coding-agent sessions Ghost watches (`status_overview` covers those).
@MainActor
package enum AgentMCP {
    package static let names: Set<String> = ["agents_list", "agents_get"]

    package static var tools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }
        return [
            tool("agents_list", "List the agents ironpet has: each one's id, number, name, pet, agent CLI, model, instructions and tool permissions."),
            tool("agents_get", "Get one agent by id, such as agent_default for agent 1.", ["id": ["type": "string"]], required: ["id"]),
        ]
    }

    package static func json(_ record: AgentRecord) -> [String: Any] {
        var object: [String: Any] = ["id": record.id, "number": record.number, "name": record.name, "agentCli": record.agentCli,
                                     "instructions": record.instructions, "permissions": record.permissions]
        if let pet = record.pet { object["pet"] = pet }
        if let model = record.model { object["model"] = model }
        return object
    }

    package static func call(_ name: String, _ arguments: [String: Any], api: AgentRecordsAPI) -> Result<Any, AutomationError> {
        switch name {
        case "agents_list":
            return .success(["agents": api.list().map(json)])
        case "agents_get":
            guard let id = arguments["id"] as? String, !id.isEmpty else { return .failure(.init(message: "id is required")) }
            do {
                return .success(json(try api.get(id)))
            } catch {
                return .failure(.init(message: (error as? APIError)?.message ?? error.localizedDescription))
            }
        default:
            return .failure(.init(message: "unknown agent tool \(name)"))
        }
    }
}
