import Foundation

/// Context prepended to the first turn of a thread: who Ghost is, what it remembers about the user, the project and the people
/// the message names, and how to use the memory and task tools. Reading the notes writes nothing.
@MainActor
package enum MemoryPreamble {
    /// Bytes of each scope's notes the chat context carries: `memory.recallBytesMe`, `memory.recallBytesProject` and `memory.recallBytesPeople`.
    package static var budget: [MemoryScope: Int] {
        let memory = ConfigStore.shared.config.memory
        return [.me: memory.recallBytesMe, .project: memory.recallBytesProject, .people: memory.recallBytesPeople]
    }

    /// What the system prompt says about tasks and regular checks. Editable: `prompts/task-instructions.md`.
    package static var taskInstructions: String { Prompts.text("task-instructions") }

    /// What the system prompt says about memory. Editable: `prompts/memory-instructions.md`.
    package static var memoryInstructions: String { Prompts.text("memory-instructions") }

    /// A background job leaves out the task list rules (`keepsTasks: false`): ironpet keeps the job's own task.
    /// The layout is `prompts/chat-preamble.md`; the notes and their paths are filled in here.
    package static func build(store: MemoryStore, workspace: URL, firstMessage: String, keepsTasks: Bool = true) -> String {
        let name = Config.load().config.pet.name
        let project = MemoryMCP.project(workspace)
        func block(_ scope: MemoryScope, about: String? = nil) -> String {
            let label = store.location(scope, project: project) ?? scope.rawValue
            let subject = about.map { " about=\"\($0)\"" } ?? ""
            let notes = store.recall(scope, project: project, bytes: budget[scope]!, naming: firstMessage)
            return "<memory page=\"\(label)\"\(subject)>\n\(notes.isEmpty ? "(none yet)" : notes)\n</memory>"
        }
        var blocks = [block(.me)]
        if let project {
            blocks.append(block(.project, about: project.isRepo ? "the \(project.name) repo (\(project.key))" : "the \(project.name) folder"))
        }
        blocks.append(block(.people))
        return Prompts.render(id: "chat-preamble", [
            "name": name,
            "blocks": blocks.joined(separator: "\n"),
            "memory": memoryInstructions,
            "tasks": keepsTasks ? "\n" + taskInstructions + "\n" : "",
        ])
    }
}
