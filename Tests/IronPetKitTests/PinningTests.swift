import XCTest
@testable import IronPetKit

/// S3: a pinned certificate connects, a different one fails before any request is sent.
final class PinningTests: XCTestCase {
    func trust(for pair: TestCertificates.Pair) throws -> SecTrust {
        let identity = try pair.identity()
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(try XCTUnwrap(certificate), SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }

    func testFingerprintMatchesOpenSSLs() throws {
        let leaf = try XCTUnwrap(PinnedSessionDelegate.leaf(of: try trust(for: TestCertificates.A)))
        XCTAssertEqual(PinnedSessionDelegate.fingerprint(of: leaf), TestCertificates.A.fingerprint)
    }

    func testDelegateAcceptsOnlyTheMatchingCertificate() throws {
        let delegate = PinnedSessionDelegate(pin: TestCertificates.A.fingerprint.uppercased())
        XCTAssertTrue(delegate.accepts(try trust(for: TestCertificates.A)))
        XCTAssertFalse(delegate.accepts(try trust(for: TestCertificates.B)))
    }

    func testMatchingCertificateConnects() async throws {
        let server = MockIronPetServer(tlsIdentity: try TestCertificates.A.identity())
        try server.start()
        defer { server.stop() }
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL, pin: TestCertificates.A.fingerprint), token: server.token)
        let items = try await client.suggestions()
        XCTAssertEqual(items.count, MockIronPetServer.sampleSuggestions.count)
    }

    func testOtherCertificateFailsAndNothingIsSent() async throws {
        let server = MockIronPetServer(tlsIdentity: try TestCertificates.B.identity())
        try server.start()
        defer { server.stop() }
        let link = try PairingLink(parsing: server.pairingLink(fingerprint: TestCertificates.A.fingerprint))
        do {
            _ = try await PairingFlow(link: link, deviceName: "Phone", pollInterval: .milliseconds(10)).run()
            XCTFail("expected the connection to fail")
        } catch {
            guard case .transport = error as? ClientError else { return XCTFail("\(error)") }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(server.requests.isEmpty, "the pairing code must not reach a server with another certificate")
    }

    func testSelfSignedCertificateWithoutAPinIsRefused() async throws {
        let server = MockIronPetServer(tlsIdentity: try TestCertificates.A.identity())
        try server.start()
        defer { server.stop() }
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        do { _ = try await client.suggestions(); XCTFail("normal validation must refuse a self-signed certificate") } catch {
            guard case .transport = error as? ClientError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(server.requests.isEmpty)
    }
}
