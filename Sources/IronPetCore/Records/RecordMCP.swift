import Foundation

/// The `get` tool: one record by its id, whatever its kind. `MCPEndpoint` resolves the id with `RecordResolver`, then the tool that already
/// reads that kind does the work, so the answer has the same shape as `tasks_get`, `jobs_get` or `automations_get`.
package enum RecordMCP {
    package static let name = "get"

    package static let tools: [[String: Any]] = [
        ["name": name,
         "description": "Get one record by its id, whatever its kind: a task (task_…), a background job (job_…), an automation (auto_…) or a "
            + "saved quick filter (filter_…). Old ids also work: a task's slug, a job's job-… id, an automation's id or a filter's id. "
            + "Returns the record as the tool for its kind would.",
         "inputSchema": ["type": "object",
                         "properties": ["id": ["type": "string", "minLength": 1, "description": "A record id, such as task_9f3c1e"]],
                         "required": ["id"]]],
    ]

    /// The tool and arguments that read a record of this kind. Nil for a filter, which has no `*_get` tool: `MCPEndpoint` reads it from the list.
    package static func target(_ kind: RecordKind, key: String) -> (tool: String, arguments: [String: Any])? {
        switch kind {
        case .task: return ("tasks_get", ["id": key])
        case .job: return ("jobs_get", ["id": key])
        case .auto: return ("automations_get", ["id": key])
        default: return nil
        }
    }
}
