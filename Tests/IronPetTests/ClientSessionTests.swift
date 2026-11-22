import XCTest
@testable import IronPet
@testable import IronPetCore

/// S1 on the Mac: the app registers as the local client with the capabilities of its platform adapters, a paired phone is a session while
/// its event socket is open, and a remote client's captures go through the same privacy gate as the Mac's own.
@MainActor
final class ClientSessionTests: XCTestCase {
    private var h: RemoteServerHarness!

    override func setUp() async throws {
        h = RemoteServerHarness()
        try await h.start()
    }

    override func tearDown() async throws { await h.stop() }

    // MARK: The local client

    func testTheMacAdvertisesOneCapabilityForEveryRealAdapter() {
        let platform = PlatformTests.macPlatform()
        let clients = ClientRegistry()
        let session = clients.registerLocal(name: "Test Mac", kind: .mac, platform: platform, extra: [.desktop])
        XCTAssertEqual(session.kind, .mac)
        XCTAssertEqual(session.connection, .inProcess)
        XCTAssertEqual(Set(session.capabilities.map(\.rawValue)),
                       Set(["screen", "presence", "secrets", "processes", "log", "appInfo", "clock", "meetings", "speech", "petAssets", "files", "openURL", "audio", "desktop"]))
    }

    func testAnUnsupportedAdapterIsNotAdvertised() {
        var platform = PlatformTests.macPlatform()
        platform.secrets = UnsupportedSecretStore()
        platform.capture = UnsupportedCaptureControl()
        let capabilities = ClientRegistry().registerLocal(name: "Mac", kind: .mac, platform: platform).capabilities.map(\.rawValue)
        XCTAssertFalse(capabilities.contains("secrets"))
        XCTAssertFalse(capabilities.contains("screen"))
        XCTAssertTrue(capabilities.contains("presence"))
        XCTAssertFalse(capabilities.contains("desktop"), "desktop control is only advertised once its tools exist")
    }

    // MARK: Paired phones

    private func socketRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(h.port)/v1/events")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func waitForSessions(_ count: Int) async throws {
        for _ in 0..<100 where h.api.clients.sessions.count != count { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(h.api.clients.sessions.count, count)
    }

    func testAPairedPhoneIsASessionWhileItsEventSocketIsOpen() async throws {
        let paired = try await h.pairDevice(name: "Ana's iPhone")
        XCTAssertEqual(h.api.clients.sessions, [])
        let socket = h.session.webSocketTask(with: socketRequest(token: paired.token))
        socket.resume()
        _ = try await socket.receive()
        try await waitForSessions(1)
        let session = try XCTUnwrap(h.api.clients.sessions.first)
        XCTAssertEqual(session.deviceID, paired.deviceID)
        XCTAssertEqual(session.kind, .ios)
        XCTAssertEqual(session.name, "Ana's iPhone")
        XCTAssertEqual(session.connection, .remote)
        socket.cancel(with: .normalClosure, reason: nil)
        try await waitForSessions(0)
    }

    func testRevokingAPhoneEndsItsSession() async throws {
        let paired = try await h.pairDevice()
        let socket = h.session.webSocketTask(with: socketRequest(token: paired.token))
        socket.resume()
        _ = try await socket.receive()
        try await waitForSessions(1)
        h.service.revoke(paired.deviceID)
        try await waitForSessions(0)
    }

    func testHelloOnTheSocketAnswersWithTheSessionAndOpensNoSecondOne() async throws {
        let paired = try await h.pairDevice()
        let socket = h.session.webSocketTask(with: socketRequest(token: paired.token))
        socket.resume()
        _ = try await socket.receive()
        try await waitForSessions(1)
        let request = #"{"jsonrpc":"2.0","id":1,"method":"session.hello","params":{"protocol":1,"client":{"name":"ironpet-ios","version":"1.4.0"},"lastSeq":0}}"#
        try await socket.send(.string(request))
        var result: [String: Any]?
        for _ in 0..<10 where result == nil {
            guard case .string(let text) = try await socket.receive() else { continue }
            let frame = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            if frame["jsonrpc"] as? String == "2.0" { result = frame }
        }
        let reply = try XCTUnwrap(result)
        XCTAssertEqual(reply["id"] as? Int, 1)
        let body = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(body["protocol"] as? Int, 1)
        XCTAssertEqual(body["gap"] as? Bool, false)
        XCTAssertEqual(body["session"] as? String, h.api.clients.sessions.first?.id)
        XCTAssertEqual(h.api.clients.sessions.count, 1)
        XCTAssertEqual(h.api.clients.sessions.first?.client?.name, "ironpet-ios")

        // The socket takes no other method.
        try await socket.send(.string(#"{"jsonrpc":"2.0","id":2,"method":"settings.get"}"#))
        var refusal: [String: Any]?
        for _ in 0..<10 where refusal == nil {
            guard case .string(let text) = try await socket.receive() else { continue }
            let frame = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            if frame["id"] as? Int == 2 { refusal = frame }
        }
        XCTAssertEqual((refusal?["error"] as? [String: Any])?["code"] as? Int, -32601)
        socket.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: A phone's chat turn

    func testAChatTurnFromAPhoneCarriesTheDeviceID() throws {
        XCTAssertEqual(ChatOrigin.ios(device: "phone-9"), ChatOrigin(client: "ios", ref: "phone-9", device: "phone-9"))
    }
}

/// `CaptureService.ingest`: captures a client took and redacted.
final class CaptureIngestTests: XCTestCase {
    private func service(config: Config.ScreenCapture = Config.ScreenCapture()) -> (CaptureService, CaptureStore) {
        let store = CaptureFixtures.store()
        var deps = CaptureService.Dependencies()
        deps.screenLocked = { false }
        return (CaptureService(store: store, config: { config }, dependencies: deps), store)
    }

    private func capture(app: String = "com.example.editor", lines: [String]) -> ClientCapture {
        ClientCapture(app: app, appName: "Editor", title: "main.swift", trigger: "idle", lines: lines, redacted: true)
    }

    func testRedactedCapturesAreStoredAndCounted() throws {
        let (service, store) = service()
        let result = try service.ingest([capture(lines: ["Reviewing the diff"]), capture(lines: [])])
        XCTAssertEqual(result, ScreenIngestResult(stored: 1, unchanged: 0, skipped: 1))
        XCTAssertEqual(store.recent(limit: 5).count, 1)
        let again = try service.ingest([capture(lines: ["Reviewing the diff"])])
        XCTAssertEqual(again.unchanged, 1, "the same text twice adds nothing")
    }

    func testTheStoreStillRedactsWhatItKeeps() throws {
        let (service, store) = service()
        _ = try service.ingest([capture(lines: ["password: hunter2-hunter2", "AKIAIOSFODNN7EXAMPLE is the key"])])
        let text = store.recent(limit: 1).first?.text ?? ""
        XCTAssertFalse(text.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    func testAPausedCaptureIsSkippedLikeAnyOtherCapture() throws {
        let (service, store) = service()
        service.privacy.pause(for: 600)
        let result = try service.ingest([capture(lines: ["Reviewing the diff"])])
        XCTAssertEqual(result, ScreenIngestResult(stored: 0, unchanged: 0, skipped: 1))
        XCTAssertEqual(store.recent(limit: 5).count, 0)
    }

    func testADeniedAppIsSkipped() throws {
        let (service, store) = service()
        service.privacy.setExcluded(["com.example.editor"])
        let result = try service.ingest([capture(lines: ["Reviewing the diff"])])
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(store.recent(limit: 5).count, 0)
    }
}
