#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Where the Mac's certificate and its private key live between launches: two base64 lines, the P-256 key and the DER certificate.
package protocol RemoteKeyStorage: AnyObject {
    func load() -> Data?
    func save(_ key: Data)
    func erase()
}

/// A file in `~/.ironpet/remote/` readable by the user only, like the hook server's token.
package final class FileKeyStorage: RemoteKeyStorage {
    private let file: URL

    package init(file: URL = Paths.root.appendingPathComponent("remote/identity.key")) { self.file = file }

    package func load() -> Data? {
        try? Data(contentsOf: file)
    }

    package func save(_ key: Data) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created with the final mode, so the key is never readable by others even for an instant.
        FileManager.default.createFile(atPath: file.path, contents: key, attributes: [.posixPermissions: 0o600])
    }

    package func erase() { try? FileManager.default.removeItem(at: file) }
}

package final class MemoryKeyStorage: RemoteKeyStorage {
    package init() {}

    private var key: Data?
    package func load() -> Data? { key }
    package func save(_ key: Data) { self.key = key }
    package func erase() { key = nil }
}

/// The Mac's identity for pairing: a P-256 key and a self-signed certificate, made the first time the remote API is turned on. The server
/// presents this certificate on the network address. The QR code carries the SHA-256 of its DER encoding, and the phone accepts only a
/// server whose certificate has that hash, so a stranger on the same Wi-Fi cannot stand in for the Mac.
package final class RemoteIdentity: @unchecked Sendable {
    package struct Material {
        package init(key: P256.Signing.PrivateKey, der: Data) {
            self.key = key
            self.der = der
        }

        package var key: P256.Signing.PrivateKey
        package var der: Data
    }

    private let storage: RemoteKeyStorage
    private let lock = NSLock()
    private var loaded: Material?

    package init(storage: RemoteKeyStorage) { self.storage = storage }

    private func current() -> Material {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        if let decoded = Self.decode(storage.load()) {
            loaded = decoded
            return decoded
        }
        return replace()
    }

    /// Caller holds the lock.
    private func replace() -> Material {
        let made = Self.make()
        storage.save(Self.encode(made))
        loaded = made
        return made
    }

    /// Makes the certificate now if there is none, so the first pairing code already has a fingerprint.
    package func ensure() { _ = current() }

    /// The certificate, DER encoded.
    package var certificateDER: Data { current().der }

    /// Lowercase hex SHA-256 of the DER certificate. This is the `f` value of the pairing link.
    package var fingerprint: String { RemoteHash.hex(current().der) }

    /// The key and the certificate, for the HTTPS listener.
    package var material: Material { current() }

    /// Replaces the key and the certificate. Every fingerprint handed out before stops matching.
    package func rotate() {
        lock.lock()
        defer { lock.unlock() }
        _ = replace()
    }

    private static func encode(_ material: Material) -> Data {
        Data("\(material.key.rawRepresentation.base64EncodedString())\n\(material.der.base64EncodedString())\n".utf8)
    }

    /// Nil for a missing file, a file of the older Ed25519 format (one line) or damaged content, so a new identity is made.
    private static func decode(_ data: Data?) -> Material? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count == 2, let raw = Data(base64Encoded: lines[0]), let der = Data(base64Encoded: lines[1]),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        return Material(key: key, der: der)
    }

    /// A self-signed certificate for a fresh key, valid ten years. Phones pin its hash, so the name and the dates are not checked.
    private static func make() -> Material {
        let key = P256.Signing.PrivateKey()
        return Material(key: key, der: SelfSignedCertificate.der(key: key, commonName: "ironpet", now: Date()))
    }
}

/// A minimal X.509 v3 certificate in DER, signed with its own P-256 key (ECDSA with SHA-256). Written by hand so the app needs no
/// certificate library: the fields are version 3, a random serial, the signature algorithm, issuer and subject `CN=<name>`, a validity of
/// ten years from a day ago, the public key, and two extensions (not a CA, and server authentication).
package enum SelfSignedCertificate {
    package static func der(key: P256.Signing.PrivateKey, commonName: String, now: Date) -> Data {
        let ecdsaWithSHA256 = sequence(oid([1, 2, 840, 10045, 4, 3, 2]))
        let name = sequence(set(sequence(oid([2, 5, 4, 3]) + tlv(0x0C, Data(commonName.utf8)))))
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7F
        serial[0] |= 0x01
        let validity = sequence(time(now.addingTimeInterval(-86_400)) + time(now.addingTimeInterval(10 * 365 * 86_400)))
        let notCA = sequence(oid([2, 5, 29, 19]) + tlv(0x01, Data([0xFF])) + tlv(0x04, sequence(Data())))
        let serverAuth = sequence(oid([2, 5, 29, 37]) + tlv(0x04, sequence(oid([1, 3, 6, 1, 5, 5, 7, 3, 1]))))
        let tbs = sequence(
            tlv(0xA0, tlv(0x02, Data([0x02])))
                + tlv(0x02, serial)
                + ecdsaWithSHA256
                + name
                + validity
                + name
                + key.publicKey.derRepresentation
                + tlv(0xA3, sequence(notCA + serverAuth)))
        // `signature(for:)` hashes with SHA-256, which is what ecdsa-with-SHA256 names.
        let signature = (try? key.signature(for: tbs).derRepresentation) ?? Data()
        return sequence(tbs + ecdsaWithSHA256 + tlv(0x03, Data([0x00]) + signature))
    }

    package static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        let count = value.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var bytes: [UInt8] = []
            var rest = count
            while rest > 0 { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + value
    }

    package static func sequence(_ content: Data) -> Data { tlv(0x30, content) }
    package static func set(_ content: Data) -> Data { tlv(0x31, content) }

    package static func oid(_ arcs: [UInt]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 { chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    /// UTCTime up to 2049, GeneralizedTime after, as RFC 5280 asks.
    package static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(formatter.string(from: date).utf8))
    }
}
