import CryptoKit
import Foundation
import IronPetCore
import Security

/// Network.framework takes the server's certificate and key only as a `SecIdentity`, and macOS makes one only from items in a keychain.
/// This keychain lives in the temporary folder while the HTTPS listener runs: the running binary imports the key and the certificate into it,
/// so the items belong to this build and macOS shows no Keychain prompt, even after an update with a new ad-hoc signature. Nothing is added
/// to the login keychain or the keychain search list. The key file in `~/.ironpet/remote/` stays the only lasting copy.
final class RemoteTLSKeychain {
    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)
        case certificate
        case identity(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status): return "could not create the TLS keychain (\(status))"
            case .certificate: return "the remote API certificate is damaged"
            case .identity(let status): return "could not make the TLS identity (\(status))"
            }
        }
    }

    let identity: SecIdentity
    let keychain: SecKeychain
    private let file: URL
    /// The random password, kept so the keychain can be unlocked again if something locks it. It never leaves the process.
    private let password: String
    private var unlockTask: Task<Void, Never>?

    private static let prefix = "ironpet-remote-"
    private static let suffix = ".keychain-db"

    /// `ironpet-remote-<pid>-<uuid>.keychain-db`. The process id tells a later launch whether the file still belongs to a running app.
    private static func fileName() -> String {
        "\(prefix)\(getpid())-\(UUID().uuidString)\(suffix)"
    }

    /// Deletes keychain files of earlier runs that a crash or a kill left behind: those of a process that is gone, those of this process
    /// other than `keeping`, and those from before the file name carried a process id. A file of another running process is left alone.
    @discardableResult
    static func removeStale(in folder: URL = FileManager.default.temporaryDirectory, keeping: URL? = nil) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var removed: [URL] = []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let url = folder.appendingPathComponent(name)
            if let keeping, url.standardizedFileURL.path == keeping.standardizedFileURL.path { continue }
            let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
            if let pid = middle.split(separator: "-", maxSplits: 1).first.flatMap({ Int32($0) }), middle.contains("-"),
               pid != getpid(), kill(pid, 0) == 0 || errno == EPERM {
                continue
            }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }

    init(_ material: RemoteIdentity.Material, folder: URL = FileManager.default.temporaryDirectory) throws {
        let path = folder.appendingPathComponent(Self.fileName())
        file = path
        // A random password, kept in memory only. The keychain is deleted when the listener stops.
        let password = RemoteHash.random(32)
        self.password = password
        var made: SecKeychain?
        let status = password.withCString { pointer in
            SecKeychainCreate(path.path, UInt32(strlen(pointer)), pointer, false, nil, &made)
        }
        guard status == errSecSuccess, let made else { throw Failure.keychain(status) }
        keychain = made
        do {
            // A new keychain locks after five minutes and when the Mac sleeps, and a locked keychain makes every TLS handshake fail.
            var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: false, useLockInterval: false,
                                               lockInterval: UInt32(Int32.max))
            let settingsStatus = SecKeychainSetSettings(made, &settings)
            guard settingsStatus == errSecSuccess else { throw Failure.keychain(settingsStatus) }
            identity = try Self.importIdentity(material, into: made)
        } catch {
            SecKeychainDelete(made)
            try? FileManager.default.removeItem(at: path)
            throw error
        }
    }

    private static func importIdentity(_ material: RemoteIdentity.Material, into keychain: SecKeychain) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, material.der as CFData) else { throw Failure.certificate }
        // SecItemAdd refuses a SecKey made from raw bytes for a file keychain (errSecParam), and SecItemImport does not read PKCS#8 for EC
        // keys. It does read the SEC1 form (RFC 5915, "EC PRIVATE KEY"), which is built here from the raw key.
        let sec1 = SelfSignedCertificate.sequence(
            SelfSignedCertificate.tlv(0x02, Data([0x01]))
                + SelfSignedCertificate.tlv(0x04, material.key.rawRepresentation)
                + SelfSignedCertificate.tlv(0xA0, SelfSignedCertificate.oid([1, 2, 840, 10045, 3, 1, 7]))
                + SelfSignedCertificate.tlv(0xA1, SelfSignedCertificate.tlv(0x03, Data([0x00]) + material.key.publicKey.x963Representation)))
        var format = SecExternalFormat.formatOpenSSL
        var type = SecExternalItemType.itemTypePrivateKey
        var parameters = SecItemImportExportKeyParameters()
        let keyStatus = SecItemImport(sec1 as CFData, nil, &format, &type, [], &parameters, keychain, nil)
        guard keyStatus == errSecSuccess else { throw Failure.identity(keyStatus) }
        let addCertificate: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate, kSecUseKeychain as String: keychain]
        let certificateStatus = SecItemAdd(addCertificate as CFDictionary, nil)
        guard certificateStatus == errSecSuccess else { throw Failure.identity(certificateStatus) }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw Failure.identity(status) }
        return identity
    }

    /// True while the keychain is unlocked.
    var isUnlocked: Bool {
        var status: SecKeychainStatus = 0
        return SecKeychainGetStatus(keychain, &status) == errSecSuccess && status & UInt32(kSecUnlockStateStatus) != 0
    }

    /// Unlocks the keychain again with the stored password when something has locked it, such as `security lock-keychain`.
    @discardableResult
    func unlockIfLocked() -> Bool {
        if isUnlocked { return true }
        let status = password.withCString { SecKeychainUnlock(keychain, UInt32(strlen($0)), $0, true) }
        return status == errSecSuccess
    }

    /// Keeps the keychain unlocked while the listener runs: a timer checks it and unlocks it with the stored password. A handshake in the
    /// second after an outside lock can still fail, and the phone's next try works.
    func keepUnlocked(every interval: Duration = .milliseconds(500)) {
        guard unlockTask == nil else { return }
        unlockTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                self?.unlockIfLocked()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Deletes the keychain file. Call once the listener that uses the identity has stopped.
    func close() {
        unlockTask?.cancel()
        unlockTask = nil
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: file)
    }
}
