import XCTest
@testable import IronPetKit

/// The phase 5 client calls and DTOs against the mock Mac.
final class PhaseFiveClientTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    func testStatusChangesOutlineAndSearchDecode() async throws {
        let status = try await client().screenStatus()
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.captureCount, 42)
        let windows = try await client().screenChanges(since: "today", app: "Slack")
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].container, "Ana")
        XCTAssertEqual(windows[1].more, 3)
        XCTAssertEqual(RemoteScreenWindow.captureID(in: windows[0].changes[0]), 12)
        let sent = try XCTUnwrap(server.requests.last { $0.path == "/v1/screen/changes" })
        XCTAssertTrue(sent.query.contains("since=today") && sent.query.contains("app=Slack"))
        let capture = try await client().screenCapture(id: 12, depth: 4)
        XCTAssertTrue(try XCTUnwrap(capture.outline).contains("review PR 4649"))
        let hits = try await client().screenSearch("release")
        XCTAssertTrue(hits[0].snippet.contains("[redacted:"))
        do { _ = try await client().screenCapture(id: 99); XCTFail("read a missing capture") } catch ClientError.api(let status, _, _) {
            XCTAssertEqual(status, 404)
        }
    }

    func testAPauseAndAForbiddenScope() async throws {
        let paused = try await client().pauseScreen(minutes: 15)
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(try XCTUnwrap(server.requests.last { $0.path == "/v1/screen/pause" }).json["minutes"] as? Int, 15)
        server.screenAllowed = false
        do { _ = try await client().screenStatus(); XCTFail("read without the scope") } catch ClientError.api(let status, let code, let message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(code, "forbidden")
            XCTAssertTrue(message.contains("Settings"))
        }
    }

    func testTheClientKeepsNoCache() {
        XCTAssertNil(client().session.configuration.urlCache)
    }

    func testCaptureIDIsReadFromTheLastField() {
        XCTAssertEqual(RemoteScreenWindow.captureID(in: "2026-11-21T09:58+01:00 message | c12 #a1b"), 12)
        XCTAssertNil(RemoteScreenWindow.captureID(in: "2026-11-21T09:58+01:00 page | Release notes"))
    }
}
