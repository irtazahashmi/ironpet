import Foundation

/// A tool call as ACP describes it, from `tool_call`, `tool_call_update` and `session/request_permission`.
package struct ACPToolCall {
    package var id: String
    package var title: String
    /// ACP's tool kind: read, edit, delete, move, search, execute, think, fetch, switch_mode or other.
    package var kind: String
    package var rawInput: Any?
    package var paths: [String]
    /// The agent's own tool name when it gives one (the Claude adapter sends `_meta.claudeCode.toolName`).
    package var toolName: String?
    /// The tool call of the subagent this call runs under. The Claude adapter stamps `_meta.claudeCode.parentToolUseId`
    /// on every update that comes from a subagent, including a background one. Nil for the main agent's own calls.
    package var parentToolUseID: String?
    /// The answers the agent offered with `session/request_permission`, in its order. Empty for a call that is not a request.
    package var permissionOptions: [PermissionOption] = []

    package init(id: String = "", title: String = "", kind: String = "other", rawInput: Any? = nil, paths: [String] = [], toolName: String? = nil,
         parentToolUseID: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.rawInput = rawInput
        self.paths = paths
        self.toolName = toolName
        self.parentToolUseID = parentToolUseID
    }

    /// The parent tool-use id an update's `_meta` names, if it comes from a subagent.
    package static func parentID(in update: JSON) -> String? {
        let id = (((update["_meta"] as? JSON)?["claudeCode"] as? JSON)?["parentToolUseId"]) as? String
        return id?.isEmpty == false ? id : nil
    }

    package init(json: JSON) {
        self.init()
        merge(json)
    }

    /// Applies the fields an update carries; fields it leaves out keep their value.
    package mutating func merge(_ json: JSON) {
        if let value = json["toolCallId"] as? String { id = value }
        if let value = json["title"] as? String, !value.isEmpty { title = value }
        if let value = json["kind"] as? String { kind = value }
        if let value = json["rawInput"], !(value is NSNull) { rawInput = value }
        if let locations = json["locations"] as? [JSON] {
            let found = locations.compactMap { $0["path"] as? String }
            if !found.isEmpty { paths = found }
        }
        if let name = ((json["_meta"] as? JSON)?["claudeCode"] as? JSON)?["toolName"] as? String { toolName = name }
        if let parent = Self.parentID(in: json) { parentToolUseID = parent }
    }

    package var input: JSON { rawInput as? JSON ?? [:] }

    /// The shell command, from the arguments or, when the agent sends none, from a title like "`ls .`".
    package var command: String {
        if let text = input["command"] as? String { return text }
        if let parts = input["command"] as? [String] { return parts.joined(separator: " ") }
        if let text = rawInput as? String { return text }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
    }

    /// The file a tool reads or changes.
    package var path: String? {
        paths.first ?? (input["file_path"] ?? input["path"] ?? input["target_file"] ?? input["notebook_path"]) as? String
    }

    /// Every path the call names, a move's destination included.
    package var allPaths: [String] {
        let keys = ["file_path", "path", "target_file", "notebook_path", "source", "destination", "new_path", "old_path", "target", "from", "to"]
        return paths + keys.compactMap { input[$0] as? String }.filter { !$0.isEmpty }
    }

    /// Everything the agent passes in, as text for the approval card.
    package var arguments: String {
        if let text = rawInput as? String { return text }
        guard let object = rawInput, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Splits `mcp__server__tool` into its server and tool. Nil for tools that are not MCP names.
    package var mcp: (server: String, tool: String)? {
        for name in [toolName, title] {
            guard let name, name.hasPrefix("mcp__") else { continue }
            let parts = name.components(separatedBy: "__")
            if parts.count >= 3 { return (parts[1], parts.dropFirst(2).joined(separator: "__")) }
        }
        return nil
    }

    /// One line for the transcript, e.g. "Ran `npm test`".
    package var summary: String {
        let file = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch kind {
        case "execute":
            let text = command.replacingOccurrences(of: "\n", with: " ")
            return "Ran `\(text.isEmpty ? "a command" : String(text.prefix(120)))`"
        case "edit": return "Edited \(file ?? "a file")"
        case "delete": return "Deleted \(file ?? "a file")"
        case "move": return "Moved \(file ?? "a file")"
        case "read": return "Read \(file ?? "a file")"
        case "search": return "Searched the codebase"
        case "fetch": return "Searched the web"
        default: return title.isEmpty ? "Used a tool" : title
        }
    }
}

package enum ApprovalPolicy: Equatable {
    case allow
    case ask(title: String, detail: String)
}

package enum ApprovalRules {
    /// MCP tool name prefixes treated as read-only (e.g. Sentry `search_issues`, Langfuse `getHealth`).
    package static let readOnlyMCPVerbs = ["get", "list", "search", "find", "fetch", "read", "describe", "whoami", "lookup", "show", "count"]

    package static func isReadOnlyMCP(_ tool: String) -> Bool {
        let name = tool.lowercased()
        return readOnlyMCPVerbs.contains { name == $0 || name.hasPrefix($0 + "_") || name.hasPrefix($0) && tool.dropFirst($0.count).first?.isUppercase == true }
    }

    /// ironpet's own task tools only read and write rows in `ironpet.db` and run nothing. Delete still asks. The `screen_*` tools only
    /// read the stored, redacted captures. The `memory_*` tools write claims in `ironpet.db`, and `memory_forget` only moves them to a
    /// page's history, so none of them can lose anything. The project, area, goal and key-result upserts keep no history, but they only rewrite metadata the agent keeps for the user. Of the assistant tools, those that start, steer or stop a job still ask.
    package static let ownTaskTools: Set<String> = Set(["tasks_list", "tasks_get", "tasks_create", "tasks_update", "tasks_close", "tasks_suggest",
                                         "tasks_suggestions_list", "tasks_suggestion_accept", "tasks_suggestion_reject",
                                         "task_filters_list", "task_filters_upsert", "task_filters_reorder", "task_projects_list", "task_projects_upsert", "task_goals_list", "task_goals_upsert", "task_areas_upsert", "task_key_results_upsert",
                                         "screen_search", "screen_window", RecordMCP.name]).union(plainNamedTools)

    /// Tools whose names are plain enough (`memory_forget`, `status_overview`) to belong to another server.
    package static let plainNamedTools: Set<String> = AssistantMCP.ownTools.union(MemoryMCP.names).union([RecordMCP.name])

    /// Agents that name MCP tools `mcp__<server>__<tool>` must name the ironpet server; others report the bare tool name.
    package static func isOwnTaskTool(server: String?, tool: String) -> Bool {
        guard ownTaskTools.contains(tool) else { return false }
        if plainNamedTools.contains(tool) { return server == "ironpet" }
        return server == nil || server == "ironpet"
    }

    /// What a request's card says. A chat shows one for every request the agent sends, whatever its kind.
    package static func card(for call: ACPToolCall) -> (title: String, detail: String) {
        switch call.kind {
        case "read", "search", "think", "fetch":
            let target = call.path.map { URL(fileURLWithPath: $0).lastPathComponent }
            return (call.title.isEmpty ? "Use \(call.kind)\(target.map { " on " + $0 } ?? "")?" : call.title + "?", String(call.arguments.prefix(600)))
        case "execute":
            return ("Run this command?", call.command)
        case "edit", "delete", "move":
            let preview = ((call.input["content"] ?? call.input["new_string"] ?? call.input["new_source"]) as? String)?
                .split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
            let verb = call.kind == "delete" ? "Delete" : call.kind == "move" ? "Move" : "Edit"
            let title = call.path.map { "\(verb) \(URL(fileURLWithPath: $0).lastPathComponent)?" } ?? "\(verb) a file?"
            return (title, [call.path, preview].compactMap { $0 }.joined(separator: "\n\n"))
        case "switch_mode":
            // Claude's exit-plan-mode request carries the plan as text. Show all of it: the user is approving it.
            let plan = call.input["plan"] as? String
            return (call.title.isEmpty ? "Change the mode?" : call.title, String((plan ?? call.arguments).prefix(6000)))
        default:
            let mcp = call.mcp
            let tool = mcp?.tool ?? call.toolName ?? call.title
            let target = mcp.map { " (\($0.server))" } ?? ""
            return ("Use " + tool + target + "?", String(call.arguments.prefix(600)))
        }
    }

    /// Whether a run with nobody at the chat answers a permission request itself (a read, a read-only MCP
    /// tool, ironpet's own tools) or must ask. The agent only asks about calls its mode treats as risky, and ironpet applies no
    /// pattern of its own: no command is judged by its text. A chat does not use this, it shows a card for every request.
    package static func policy(for call: ACPToolCall) -> ApprovalPolicy {
        switch call.kind {
        case "read", "search", "think", "fetch":
            return .allow
        case "execute":
            return .ask(title: "Run this command?", detail: call.command)
        case "edit", "delete", "move":
            let card = card(for: call)
            return .ask(title: card.title, detail: card.detail)
        default:
            // MCP servers can change real systems (databases, issue trackers), so anything not read-only asks first.
            let mcp = call.mcp
            let tool = mcp?.tool ?? call.toolName ?? call.title
            if isReadOnlyMCP(tool) || isOwnTaskTool(server: mcp?.server, tool: tool) { return .allow }
            let card = card(for: call)
            return .ask(title: card.title, detail: card.detail)
        }
    }
}
