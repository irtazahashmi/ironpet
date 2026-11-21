import Foundation

/// The transcription server's API key, kept in the secret store (service `ironpet.voice`) and never written to
/// `~/.ironpet`. Same approach as the Sentry token.
struct VoiceKey: Sendable {
    static let service = "ironpet.voice"
    static let account = "api-key"

    var store: SecretStore

    /// A key that never finds anything, for owners `AppDelegate` has not wired yet and for tests that do not need a key.
    static var unsupported: VoiceKey { VoiceKey(store: UnsupportedSecretStore()) }

    func load() -> String? {
        // An automated run must never wait on a Keychain approval dialog. The test server needs no key.
        if CommandLine.arguments.contains("--test-mode") { return nil }
        return store.text(service: Self.service, account: Self.account)
    }

    var isSet: Bool { load() != nil }

    /// Stores `key`, replacing any earlier one. An empty key removes it.
    @discardableResult
    func save(_ key: String) -> Bool {
        store.save(text: key, service: Self.service, account: Self.account)
    }

    func delete() {
        try? store.delete(service: Self.service, account: Self.account)
    }
}
