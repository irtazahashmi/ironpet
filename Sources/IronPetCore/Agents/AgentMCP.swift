import Foundation

/// The agent record tools agents see (served by `MCPEndpoint` at `POST /mcp`): list and get an agent, and create, update and delete one,
/// all through `AgentRecordsAPI`.
/// `agents_list` is about agent records, not the coding-agent sessions Ghost watches (`status_overview` covers those).
@MainActor
package enum AgentMCP {
    package static let names: Set<String> = ["agents_list", "agents_get", "agents_create", "agents_update", "agents_delete"]

    package static var tools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }
        return [
            tool("agents_list", "List the agents ironpet has: each one's id, number, name, pet, agent CLI, model, instructions and tool permissions."),
            tool("agents_get", "Get one agent by id, such as agent_default for agent 1.", ["id": ["type": "string"]], required: ["id"]),
            tool("agents_create", "Create an agent. It starts enabled: ironpet starts its process and shows its pet.",
                 ["name": ["type": "string"], "agentCli": ["type": "string", "description": "The agent CLI, such as cursor, claude or codex."],
                  "pet": ["type": "string", "description": "Path to the pet's sprite sheet. Leave out for the bundled Ghost."],
                  "model": ["type": "string"], "instructions": ["type": "string"]], required: ["name", "agentCli"]),
            tool("agents_update", "Change an agent. Leave a field out to keep it. An empty pet or model clears it. enabled=false stops the agent's process and hides its pet, and its chats stay; enabled=true brings them back.",
                 ["id": ["type": "string"], "name": ["type": "string"], "agentCli": ["type": "string"], "pet": ["type": "string"],
                  "model": ["type": "string"], "instructions": ["type": "string"], "enabled": ["type": "boolean"]], required: ["id"]),
            tool("agents_delete", "Delete an agent. Its chats and automations stay on disk but are no longer listed. Refused while it owns an enabled automation. Agent 1 cannot be deleted.",
                 ["id": ["type": "string"]], required: ["id"]),
        ]
    }

    package static func json(_ record: AgentRecord) -> [String: Any] {
        var object: [String: Any] = ["id": record.id, "number": record.number, "name": record.name, "agentCli": record.agentCli,
                                     "instructions": record.instructions, "permissions": record.permissions]
        if let pet = record.pet { object["pet"] = pet }
        if let model = record.model { object["model"] = model }
        object["enabled"] = record.enabled
        return object
    }

    private static func run(_ body: () throws -> Any) -> Result<Any, AutomationError> {
        do {
            return .success(try body())
        } catch {
            return .failure(.init(message: (error as? APIError)?.message ?? error.localizedDescription))
        }
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
        case "agents_create":
            guard let name = arguments["name"] as? String, let cli = arguments["agentCli"] as? String else { return .failure(.init(message: "name and agentCli are required")) }
            return run { json(try api.create(CreateAgentRequest(name: name, agentCli: cli, pet: arguments["pet"] as? String, model: arguments["model"] as? String,
                                                              instructions: arguments["instructions"] as? String))) }
        case "agents_update":
            guard let id = arguments["id"] as? String, !id.isEmpty else { return .failure(.init(message: "id is required")) }
            return run { json(try api.update(UpdateAgentRequest(id: id, name: arguments["name"] as? String, pet: arguments["pet"] as? String,
                                                              agentCli: arguments["agentCli"] as? String, model: arguments["model"] as? String,
                                                              instructions: arguments["instructions"] as? String, enabled: arguments["enabled"] as? Bool))) }
        case "agents_delete":
            guard let id = arguments["id"] as? String, !id.isEmpty else { return .failure(.init(message: "id is required")) }
            return run { try api.delete(id); return ["deleted": id] }
        default:
            return .failure(.init(message: "unknown agent tool \(name)"))
        }
    }
}
