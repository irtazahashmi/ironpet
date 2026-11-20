import CryptoKit
import Foundation
import Security

/// Accepts a server certificate only when its SHA-256 matches the pin from the pairing link. A self-signed certificate on a LAN address
/// has no chain to check, so the pin is the whole trust decision. A mismatch cancels the challenge, so the request never leaves the device.
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let pin: String

    public init(pin: String) { self.pin = Fingerprint.normalize(pin) ?? pin.lowercased() }

    /// Lowercase hex SHA-256 of the leaf certificate's DER.
    public static func fingerprint(of certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    public static func leaf(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    public func accepts(_ trust: SecTrust) -> Bool {
        guard let leaf = Self.leaf(of: trust) else { return false }
        return Self.fingerprint(of: leaf) == pin
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, accepts(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
