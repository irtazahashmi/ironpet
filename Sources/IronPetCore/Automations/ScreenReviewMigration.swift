import Foundation

/// The task scan replaced the Screen review built-in. This removes the stored `screen-review` automation and tells the caller whether it
/// was enabled, so the scan's screen source can start on for a user who had it on. A `screen-review` entry whose prompt the user
/// changed is theirs: it stays and the scan's screen source stays off.
package enum ScreenReviewMigration {
    package static let automationID = "screen-review"
    package static let promptText = "{{prompt.screen-review}}"

    package enum Result: Equatable {
        /// There was no built-in `screen-review` to remove.
        case none
        case removed(wasEnabled: Bool)
        /// The file could not be read or written. The next launch tries again.
        case failed
    }

    /// Removes the entry and, when it was enabled, turns the scan's screen source on. The config changes only after the entry is gone,
    /// so a failed write leaves both as they were and the next launch tries again.
    @MainActor
    @discardableResult
    package static func run(store: AutomationStore, config: ConfigStore) -> Result {
        let result = remove(from: store)
        if case .removed(wasEnabled: true) = result { config.update { $0.tasks.scanScreen = true } }
        return result
    }

    @MainActor
    package static func remove(from store: AutomationStore) -> Result {
        guard store.error == nil else { return .failed }
        guard let found = store.automations.first(where: isBuiltIn) else { return .none }
        guard (try? store.replace(store.automations.filter { !isBuiltIn($0) })) != nil else { return .failed }
        return .removed(wasEnabled: found.enabled)
    }

    private static func isBuiltIn(_ a: Automation) -> Bool {
        a.id == automationID && a.action.type == "prompt" && a.action.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) == promptText
    }
}
