import Foundation

/// Where secrets live, addressed by service and account. The Mac adapter is the Keychain.
protocol SecretStore: Sendable {
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
    var isSupported: Bool { true }

    /// The value as trimmed text, or nil when it is missing, unreadable or blank. Callers that treat every failure as "no secret" use this.
    func text(service: String, account: String) -> String? {
        guard let data = try? get(service: service, account: account) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Stores trimmed `text`, replacing any earlier value. Blank text removes it. Returns false when the store refused.
    @discardableResult
    func save(text: String, service: String, account: String) -> Bool {
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
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func get(service: String, account: String) throws -> Data? { lock.withLock { values["\(service)\u{0}\(account)"] } }
    func set(_ value: Data, service: String, account: String) throws { lock.withLock { values["\(service)\u{0}\(account)"] = value } }
    func delete(service: String, account: String) throws { lock.withLock { _ = values.removeValue(forKey: "\(service)\u{0}\(account)") } }
}

struct UnsupportedSecretStore: SecretStore {
    var platform = PlatformName.current
    var isSupported: Bool { false }
    private var error: CapabilityError { .unsupported(capability: "SecretStore", platform: platform) }
    func get(service: String, account: String) throws -> Data? { throw error }
    func set(_ value: Data, service: String, account: String) throws { throw error }
    func delete(service: String, account: String) throws { throw error }
}
