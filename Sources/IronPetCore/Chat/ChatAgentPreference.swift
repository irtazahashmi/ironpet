import Foundation

/// Resolves the chat's preferred agent id from UserDefaults, including the one-shot copy from the pre-ACP
/// `chatBackend` key into `chatAgent`. Old builds stored `cursor` or `claude` under `chatBackend`; current builds
/// only read `chatAgent`, so without this copy an upgrade drops Claude and falls back to Cursor.
package enum ChatAgentPreference {
    package static let key = "chatAgent"
    /// Pre-ACP preference key. Left in place after a copy so a second read stays idempotent.
    package static let legacyKey = "chatBackend"
    package static let defaultID = "cursor"

    /// Returns a known catalog id. When `chatAgent` is missing or unknown and `chatBackend` is a known id, writes
    /// that value into `chatAgent` and returns it. Otherwise returns `cursor`.
    package static func resolveID(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: key), AgentCatalog.agent(id: id) != nil {
            return id
        }
        if let legacy = defaults.string(forKey: legacyKey), AgentCatalog.agent(id: legacy) != nil {
            defaults.set(legacy, forKey: key)
            return legacy
        }
        return defaultID
    }
}
