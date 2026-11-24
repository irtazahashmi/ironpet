import Foundation

/// Text selected in another app when the chat opened, waiting to go with the next send as context.
package struct FrontSelection: Codable, Equatable, Sendable {
    package init(text: String, appName: String, windowTitle: String? = nil, trimmed: Bool = false) {
        self.text = text
        self.appName = appName
        self.windowTitle = windowTitle
        self.trimmed = trimmed
    }

    /// Most characters of the selection that reach the agent.
    package static let limit = 8_000

    package var text: String
    package var appName: String
    /// The frontmost window's title when known.
    package var windowTitle: String?
    /// True when `text` was cut to `limit`.
    package var trimmed: Bool

    /// Source label shown on the chip and in the agent prompt, for example `Notes — Shopping`.
    package var sourceLabel: String {
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return "\(appName) — \(title)" }
        return appName
    }

    /// Builds a selection from raw AX text, or nil when empty after trimming.
    package static func make(text: String, appName: String, windowTitle: String?) -> FrontSelection? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = (title?.isEmpty == false) ? title : nil
        if cleaned.count > limit {
            return FrontSelection(text: String(cleaned.prefix(limit)), appName: name, windowTitle: window, trimmed: true)
        }
        return FrontSelection(text: cleaned, appName: name, windowTitle: window, trimmed: false)
    }

    /// The prompt the agent receives: the selection quoted from the source app, then the user's text.
    package static func prompt(_ selection: FrontSelection, text: String) -> String {
        let body = selection.text
        let note = selection.trimmed
            ? "\n[The selection was cut here. It was longer than \(limit) characters.]"
            : ""
        let quoted = (body + note).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        return "> From \(selection.sourceLabel):\n\(quoted)\n\n\(text)"
    }
}
