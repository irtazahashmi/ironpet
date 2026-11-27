import Foundation

/// The assistant tools: hand work to background jobs (`jobs_*`), answer "what is going on" (`status_*`), keep memory
/// (`memory_*`) and find the folder a job runs in (`projects_resolve`). They read the other namespaces through the context.
@MainActor
package final class AssistantAPI {
    private let context: AssistantContext

    package init(context: AssistantContext) { self.context = context }

    package func handles(_ name: String) -> Bool { AssistantMCP.handles(name) }

    package func callTool(_ name: String, _ args: [String: Any], agent: String? = nil) -> Result<Any, JobError> {
        AssistantMCP.call(name, args, context: context, agent: agent)
    }
}
