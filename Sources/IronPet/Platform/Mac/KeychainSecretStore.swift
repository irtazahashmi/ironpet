import Foundation
import Security

/// Secrets in the macOS Keychain, as generic passwords. The items carry no accessibility attribute, as they never did, so items
/// stored before this adapter existed are still found.
struct KeychainSecretStore: SecretStore {
    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)" }
    }

    init() {}

    private func match(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func get(service: String, account: String) throws -> Data? {
        var query = match(service, account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    func set(_ value: Data, service: String, account: String) throws {
        SecItemDelete(match(service, account) as CFDictionary)
        var item = match(service, account)
        item[kSecValueData as String] = value
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(match(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
