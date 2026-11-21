import Foundation

/// Where secrets live, addressed by service and account. The Mac adapter is the Keychain.
package protocol SecretStore: Sendable {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    var isSupported: Bool { get }
    /// The stored value, or nil when there is none.
    func get(service: String, account: String) throws -> Data?
    /// Stores `value`, replacing any earlier one.
    func set(_ value: Data, service: String, account: String) throws
    /// Removes the value. Removing a missing one is not an error.
    func delete(service: String, account: String) throws
}

extension SecretStore {
    package var isSupported: Bool { true }

    /// The value as trimmed text, or nil when it is missing, unreadable or blank. Callers that treat every failure as "no secret" use this.
    package func text(service: String, account: String) -> String? {
        guard let data = try? get(service: service, account: account) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Stores trimmed `text`, replacing any earlier value. Blank text removes it. Returns false when the store refused.
    @discardableResult
    package func save(text: String, service: String, account: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try delete(service: service, account: account)
            guard !trimmed.isEmpty else { return true }
            try set(Data(trimmed.utf8), service: service, account: account)
            return true
        } catch {
            return false
        }
    }
}

/// Keeps secrets in memory. Tests use it, and `--test-mode` does, where a Keychain dialog would block an automated run.
package final class InMemorySecretStore: SecretStore, @unchecked Sendable { // `values` is touched only under `lock`.
    package init() {}

    private let lock = NSLock()
    private var values: [String: Data] = [:]

    package func get(service: String, account: String) throws -> Data? { lock.withLock { values["\(service)\u{0}\(account)"] } }
    package func set(_ value: Data, service: String, account: String) throws { lock.withLock { values["\(service)\u{0}\(account)"] = value } }
    package func delete(service: String, account: String) throws { lock.withLock { _ = values.removeValue(forKey: "\(service)\u{0}\(account)") } }
}

package struct UnsupportedSecretStore: SecretStore {
    package init() {}

    package var platform = PlatformName.current
    package var isSupported: Bool { false }
    private var error: CapabilityError { .unsupported(capability: "SecretStore", platform: platform) }
    package func get(service: String, account: String) throws -> Data? { throw error }
    package func set(_ value: Data, service: String, account: String) throws { throw error }
    package func delete(service: String, account: String) throws { throw error }
}
