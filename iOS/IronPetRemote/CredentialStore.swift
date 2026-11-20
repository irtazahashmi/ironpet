import Foundation
import IronPetKit
import Security

/// Where the pairing result lives between launches.
protocol CredentialStore: AnyObject {
    func load() -> PairedDevice?
    func save(_ device: PairedDevice) throws
    func delete()
}

/// The token sits in the Keychain, readable after the first unlock and never moved to another device by a backup or iCloud Keychain.
final class KeychainCredentialStore: CredentialStore {
    let service: String
    let account = "paired-device"

    init(service: String = "dev.ironpet.remote") { self.service = service }

    /// What identifies the item. `kSecAttrSynchronizable` false keeps it out of iCloud Keychain.
    static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// The attributes `save` adds: the base query, the data, and the accessibility class.
    static func addQuery(service: String, account: String, data: Data) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The Keychain refused the token (error \(status))." }
    }

    func load() -> PairedDevice? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairedDevice.self, from: data)
    }

    func save(_ device: PairedDevice) throws {
        let data = try JSONEncoder().encode(device)
        delete()
        let status = SecItemAdd(Self.addQuery(service: service, account: account, data: data) as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() {
        SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
    }
}

final class MemoryCredentialStore: CredentialStore {
    var device: PairedDevice?
    init(_ device: PairedDevice? = nil) { self.device = device }
    func load() -> PairedDevice? { device }
    func save(_ device: PairedDevice) throws { self.device = device }
    func delete() { device = nil }
}
