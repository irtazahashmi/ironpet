import Foundation

/// The prompts ironpet sends on its own (`Prompts`): the text in use, its default, and whether a newer default is waiting for the
/// user's choice. Settings → Prompts reads and changes them here, so the UI never touches the files.
@MainActor
package final class PromptsAPI {
    /// A newer default that the user has not taken yet, with the lines that differ from the text the user's copy was made from.
    package struct Update: Equatable {
        package let previous: String
        package let current: String
        package let changes: [Prompts.LineChange]
    }

    package struct Prompt: Equatable {
        package let id: String
        package let title: String
        package let placeholders: [String]
        package let required: [String]
        /// The text in use.
        package let text: String
        package let defaultText: String
        package let state: PromptStore.State
        /// Set while `state` is `updated`.
        package let update: Update?
    }

    package init() {}

    package func list() -> [Prompt] { Prompts.catalog.map(prompt) }

    package func get(_ id: String) throws -> Prompt {
        guard let info = Prompts.info(id) else { throw APIError.notFound("no prompt with id \"\(id)\"") }
        return prompt(info)
    }

    /// Saves the user's text. An empty prompt is refused: it would send nothing to the agent.
    package func save(_ id: String, text: String) throws -> Prompt {
        _ = try get(id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.invalid("a prompt cannot be empty; use Reset to default instead") }
        PromptStore.save(id, text: text)
        return try get(id)
    }

    /// Restores the default. Also takes a newer default that was waiting.
    package func reset(_ id: String) throws -> Prompt {
        _ = try get(id)
        PromptStore.reset(id)
        return try get(id)
    }

    /// Keeps the user's text and stops offering the newer default.
    package func keepMine(_ id: String) throws -> Prompt {
        _ = try get(id)
        PromptStore.keepMine(id)
        return try get(id)
    }

    private func prompt(_ info: PromptInfo) -> Prompt {
        let update = PromptStore.pendingUpdate(info.id).map {
            Update(previous: $0.previous, current: $0.current, changes: Prompts.diff(from: $0.previous, to: $0.current))
        }
        return Prompt(id: info.id, title: info.title, placeholders: info.placeholders, required: info.required,
                      text: PromptStore.text(info.id), defaultText: Prompts.defaultText(info.id) ?? "",
                      state: PromptStore.state(info.id), update: update)
    }
}
