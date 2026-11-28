import Foundation

/// A prompt that ironpet sends to an agent on its own, or into a chat. Its text is `~/.ironpet/prompts/<id>.md` once the
/// user has that file, and the default in `prompts/` of the repo otherwise (`BuiltInPromptsData`). `placeholders` are the
/// `{name}` values the code fills in. `required` ones are appended when the user's text leaves them out, so a run never loses
/// the message or the transcript it was built for.
package struct PromptInfo: Equatable {
    package let id: String
    package let title: String
    package let placeholders: [String]
    package let required: [String]
}

package enum Prompts {
    package static let catalog: [PromptInfo] = [
        PromptInfo(id: "chat-preamble", title: "Chat: context and instructions",
                   placeholders: ["name", "files", "blocks", "memory"], required: []),
        PromptInfo(id: "memory-instructions", title: "Chat: memory rules", placeholders: [], required: []),
        PromptInfo(id: "automation-prompt", title: "Automations: run wrapper", placeholders: ["name", "prompt"], required: ["prompt"]),
        PromptInfo(id: "meeting-summary", title: "Meetings: summary", placeholders: ["note", "transcript"], required: ["transcript"]),
        PromptInfo(id: "meeting-suggestions", title: "Meetings: title and speaker names for room and imported meetings", placeholders: [], required: []),
        PromptInfo(id: "mail-calendar", title: "Mail and calendar checks", placeholders: [], required: []),
        PromptInfo(id: "job-instructions", title: "Jobs: what the background agent is told", placeholders: ["id", "title", "folder"], required: []),
        PromptInfo(id: "memory-reflection", title: "Memory: learning from a chat",
                   placeholders: ["pet", "kind", "scopes", "notes", "rule", "input", "maxLength", "maxNotes"], required: []),
        PromptInfo(id: "memory-resort", title: "Memory: moving notes to the page they are about",
                   placeholders: ["pet", "pages", "notes"], required: []),
        PromptInfo(id: "memory-cleanup", title: "Memory: cleanup of misfiled notes and duplicate pages",
                   placeholders: ["pet", "pages", "notes"], required: []),
        PromptInfo(id: "memory-merge", title: "Memory: merging a long page", placeholders: ["pet", "claims", "maxLength"], required: []),
        PromptInfo(id: "session-handoff", title: "Chat: handoff to a new session", placeholders: [], required: []),
        PromptInfo(id: "automation-new", title: "Automations: asking the chat agent to create one", placeholders: ["request", "cli"], required: ["request"]),
        PromptInfo(id: "automation-fix", title: "Automations: asking the chat agent to fix a failed one", placeholders: ["name", "id", "trigger", "error", "cli"], required: ["error"]),
        PromptInfo(id: "automation-cli", title: "Automations: the command-line fallback line", placeholders: ["executable"], required: []),
    ]

    package static func info(_ id: String) -> PromptInfo? { catalog.first { $0.id == id } }

    /// The default text that ships with this build.
    package static func defaultText(_ id: String) -> String? { BuiltInPromptsData.all.first { $0.id == id }?.text }

    /// The text in use: the user's file, or the default. Empty for an id that is not in the catalog.
    package static func text(_ id: String) -> String { PromptStore.text(id) }

    /// Fills `{name}` placeholders from `values` in one pass. A value is inserted as it is and never scanned again, so a
    /// transcript that contains `{name}` stays as written. A `{...}` with no value stays as written too.
    package static func render(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let key = String(rest[rest.index(after: open)..<close])
            if key.contains("{") {
                // A brace with no close of its own: keep it, and look for placeholders after it.
                out += String(rest[...open])
                rest = rest[rest.index(after: open)...]
                continue
            }
            out += String(rest[..<open])
            out += values[key] ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        return out + String(rest)
    }

    /// Renders prompt `id` with `values`, and appends the required values the text leaves out.
    package static func render(id: String, _ values: [String: String]) -> String {
        let template = text(id)
        var out = render(template, values)
        for key in info(id)?.required ?? [] where !template.contains("{\(key)}") {
            if let value = values[key] { out += "\n\n" + value }
        }
        return out
    }

    /// One line of a diff between two versions of a prompt.
    package struct LineChange: Equatable {
        package let removed: Bool
        package let line: String
    }

    /// The lines that differ between `old` and `new`, in order: removed lines, then the lines that replace them.
    package static func diff(from old: String, to new: String) -> [LineChange] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var changes: [LineChange] = []
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(_, let element, _): changes.append(LineChange(removed: true, line: element))
            case .insert(_, let element, _): changes.append(LineChange(removed: false, line: element))
            }
        }
        return changes
    }
}
