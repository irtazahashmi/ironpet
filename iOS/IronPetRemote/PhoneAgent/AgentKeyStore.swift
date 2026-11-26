import Foundation
import IronPetKit
import Security

/// Where the API keys of the phone's agent live. The only implementation that keeps a key past the process is the Keychain.
protocol AgentKeyStoring: AgentKeyProviding {
    func setKey(_ key: String, for provider: AgentProvider) throws
    func removeKey(for provider: AgentProvider)
    func hasKey(for provider: AgentProvider) -> Bool
}

/// One Keychain item for each provider, readable after the first unlock and never moved to another device by a backup or iCloud Keychain.
/// The key is in no file, no `UserDefaults` and no record that syncs.
// @unchecked Sendable: `service` is a constant and the Keychain serializes access.
final class KeychainAgentKeyStore: AgentKeyStoring, @unchecked Sendable {
    let service: String

    init(service: String = "dev.ironpet.remote.agent") { self.service = service }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The Keychain refused the key (error \(status))." }
    }

    private func base(_ provider: AgentProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    func apiKey(for provider: AgentProvider) -> String? {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasKey(for provider: AgentProvider) -> Bool { apiKey(for: provider)?.isEmpty == false }

    func setKey(_ key: String, for provider: AgentProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        removeKey(for: provider)
        guard !trimmed.isEmpty else { return }
        var query = base(provider)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func removeKey(for provider: AgentProvider) { SecItemDelete(base(provider) as CFDictionary) }
}

/// A key store for tests that must not touch the Keychain.
// @unchecked Sendable: every access to `keys` holds `lock`.
final class MemoryAgentKeyStore: AgentKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [AgentProvider: String] = [:]
    func apiKey(for provider: AgentProvider) -> String? { lock.lock(); defer { lock.unlock() }; return keys[provider] }
    func hasKey(for provider: AgentProvider) -> Bool { apiKey(for: provider)?.isEmpty == false }
    func setKey(_ key: String, for provider: AgentProvider) throws { lock.lock(); keys[provider] = key.trimmingCharacters(in: .whitespacesAndNewlines); lock.unlock() }
    func removeKey(for provider: AgentProvider) { lock.lock(); keys[provider] = nil; lock.unlock() }
}

/// Provider and model. They are not secret, so they sit in `UserDefaults`. The key never does.
struct PhoneAgentSettings {
    private let defaults: UserDefaults
    static let providerKey = "phoneAgent.provider"
    static let modelKey = "phoneAgent.model"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var config: AgentConfig {
        get {
            let provider = defaults.string(forKey: Self.providerKey).flatMap(AgentProvider.init(rawValue:)) ?? .anthropic
            return AgentConfig(provider: provider, model: defaults.string(forKey: Self.modelKey))
        }
        nonmutating set {
            defaults.set(newValue.provider.rawValue, forKey: Self.providerKey)
            defaults.set(newValue.model, forKey: Self.modelKey)
        }
    }
}
