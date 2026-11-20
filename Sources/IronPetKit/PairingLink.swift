import Foundation

/// `ironpet://pair?u=<base URL>&c=<code>&f=<fingerprint>`, as the QR code and the copyable link on the Mac carry it.
public struct PairingLink: Equatable, Sendable {
    public var baseURL: URL
    public var code: String
    /// Lowercase hex SHA-256 of the server certificate's DER, no separators. Absent for a custom front, which has its own certificate.
    public var fingerprint: String?

    public init(baseURL: URL, code: String, fingerprint: String? = nil) {
        self.baseURL = baseURL; self.code = code; self.fingerprint = fingerprint
    }

    public enum ParseError: Error, Equatable { case notALink, missingAddress, missingCode, badAddress, badFingerprint }

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "ironpet", parts.host?.lowercased() == "pair" else {
            throw ParseError.notALink
        }
        func value(_ name: String) -> String? { parts.queryItems?.first { $0.name == name }?.value }
        guard let address = value("u"), !address.isEmpty else { throw ParseError.missingAddress }
        guard let code = value("c"), !code.isEmpty else { throw ParseError.missingCode }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw ParseError.badAddress
        }
        var fingerprint: String?
        if let raw = value("f"), !raw.isEmpty {
            guard let clean = Fingerprint.normalize(raw) else { throw ParseError.badFingerprint }
            fingerprint = clean
        }
        self.init(baseURL: url, code: code, fingerprint: fingerprint)
    }
}

public enum Fingerprint {
    /// Lowercase hex without colons or spaces. Nil unless the text is a SHA-256 (64 hex digits).
    public static func normalize(_ text: String) -> String? {
        let clean = text.lowercased().filter { $0 != ":" && $0 != " " }
        guard clean.count == 64, clean.allSatisfy({ $0.isHexDigit }) else { return nil }
        return clean
    }
}
