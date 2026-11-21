import IronPetKit
import XCTest
@testable import IronPet
@testable import IronPetCore

/// The screen routes of the remote API over a real listener, a real capture store and the real `ScreenMCP` tools.
@MainActor
final class RemoteScreenTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var captures: CaptureStore!
    private var token = ""
    private var deviceID = ""
    private let slack = CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", pid: 100)
    private let key = "sk-" + "proj-" + String(repeating: "Ab3d", count: 8)

    override func setUp() async throws {
        h = RemoteServerHarness()
        captures = CaptureFixtures.store()
        h.api.attach(capture: CaptureService(store: captures, config: { Config().screenCapture }))
        try await h.start()
        let paired = try await h.pairDevice()
        token = paired.token
        deviceID = paired.deviceID
    }

    override func tearDown() async throws { await h.stop() }

    private func grant(_ on: Bool = true) { XCTAssertTrue(h.service.setScreenAccess(deviceID, granted: on)) }
    private func code(_ path: String, token: String? = nil) async throws -> Int { try await h.request("GET", path, token: token ?? self.token).status }
    private func get(_ path: String) async throws -> RemoteReply { try await h.request("GET", path, token: token) }

    @discardableResult
    private func ingest(_ lines: [String], title: String = "Ana (DM)", ageSeconds: TimeInterval = 60) throws -> CaptureStore.IngestResult {
        try captures.ingest(app: slack, title: title, url: nil, trigger: .typingPause, lines: lines, now: Date().addingTimeInterval(-ageSeconds))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try WireJSON.makeDecoder().decode(type, from: data) }

    // S1
    func testTheChangeListEqualsWhatTheScreenToolReturns() async throws {
        grant()
        try ingest(["Can you review PR 4649 before lunch?", "The deploy is blocked on review"])
        try ingest(["Standup notes for Friday"], title: "Team")
        let reply = try await get("/v1/screen/changes?since=today")
        XCTAssertEqual(reply.status, 200)
        let served = try decode(RemoteScreenChanges.self, reply.data)
        let tool = try XCTUnwrap(h.api.screen).callTool("screen_window", ["since": "today"])
        guard case .success(let value) = tool else { return XCTFail("the tool failed") }
        let direct = try decode(RemoteScreenChanges.self, try JSONSerialization.data(withJSONObject: value))
        XCTAssertFalse(direct.changes.isEmpty)
        XCTAssertEqual(served, direct)
        XCTAssertEqual(reply.headers["cache-control"], "no-store")
    }

    func testTheOutlineOfACaptureAndASearchAreServed() async throws {
        grant()
        let made = try ingest(["Can you review PR 4649 before lunch?"])
        let search = try decode(RemoteScreenSearch.self, try await get("/v1/screen/search?q=review%20lunch&limit=5").data)
        XCTAssertEqual(search.hits.count, 1)
        let hit = try XCTUnwrap(search.hits.first)
        XCTAssertEqual(hit.app, "Slack")
        let capture = try await get("/v1/screen/captures/\(hit.id)")
        XCTAssertEqual(capture.status, 200)
        let detail = try decode(RemoteScreenCaptureResponse.self, capture.data).capture
        XCTAssertEqual(detail.id, hit.id)
        XCTAssertTrue(try XCTUnwrap(detail.text).contains("PR 4649"))
        _ = made
        let missing = try await get("/v1/screen/captures/99999")
        XCTAssertEqual(missing.status, 404)
        let a = try await code("/v1/screen/captures/abc"); XCTAssertEqual(a, 400)
        let b = try await code("/v1/screen/search"); XCTAssertEqual(b, 400)
        let c = try await code("/v1/screen/search?q=x&limit=51"); XCTAssertEqual(c, 400)
        let d = try await code("/v1/screen/changes?since=notatime"); XCTAssertEqual(d, 400)
    }

    func testTheStatusAndAPauseFromThePhone() async throws {
        grant()
        try ingest(["hello world"])
        h.api.screen?.refreshStatus()
        let status = try decode(RemoteScreenStatus.self, try await get("/v1/screen/status").data)
        XCTAssertEqual(status.captureCount, 1)
        XCTAssertFalse(status.paused)
        let paused = try await h.request("POST", "/v1/screen/pause", token: token, body: ["minutes": 15])
        XCTAssertEqual(paused.status, 200)
        let after = try decode(RemoteScreenStatus.self, paused.data)
        XCTAssertTrue(after.paused)
        XCTAssertNotNil(after.pausedUntil)
        let bad = try await h.request("POST", "/v1/screen/pause", token: token, body: ["minutes": 0])
        XCTAssertEqual(bad.status, 400)
        let empty = try await h.request("POST", "/v1/screen/pause", token: token, body: [:])
        XCTAssertEqual(empty.status, 400)
        let tomorrow = try await h.request("POST", "/v1/screen/pause", token: token, body: ["until": "tomorrow"])
        XCTAssertEqual(tomorrow.status, 200)
    }

    // S2
    func testASecretNextToTheMatchIsRedactedInTheSnippet() async throws {
        grant()
        try ingest(["Ship the release with key \(key) before the standup"])
        let reply = try await get("/v1/screen/search?q=release")
        XCTAssertEqual(reply.status, 200)
        let body = String(decoding: reply.data, as: UTF8.self)
        let hit = try XCTUnwrap(decode(RemoteScreenSearch.self, reply.data).hits.first)
        XCTAssertTrue(hit.snippet.contains("[redacted:"), hit.snippet)
        XCTAssertFalse(body.contains("Ab3dAb3d"))
        let capture = String(decoding: try await get("/v1/screen/captures/\(hit.id)").data, as: UTF8.self)
        XCTAssertFalse(capture.contains("Ab3dAb3d"))
    }

    // S3
    func testWithoutTheScreenScopeEveryScreenRouteIs403() async throws {
        try ingest(["hello world"])
        for path in ["/v1/screen/status", "/v1/screen/changes?since=today", "/v1/screen/captures/1", "/v1/screen/search?q=hello"] {
            let reply = try await get(path)
            XCTAssertEqual(reply.status, 403, path)
            XCTAssertFalse(String(decoding: reply.data, as: UTF8.self).contains("hello"))
        }
        let pause = try await h.request("POST", "/v1/screen/pause", token: token, body: ["minutes": 15]); XCTAssertEqual(pause.status, 403)
        XCTAssertFalse(try XCTUnwrap(h.api.screen).status.paused)
        // The scope is granted on the Mac only, and taking it back closes the routes again.
        grant()
        let on = try await code("/v1/screen/status"); XCTAssertEqual(on, 200)
        XCTAssertTrue(h.service.devices.first { $0.id == deviceID }?.has(RemoteScope.screen) ?? false)
        grant(false)
        let off = try await code("/v1/screen/status"); XCTAssertEqual(off, 403)
        // Without a token the routes are 401, scope or not.
        let anon = try await h.request("GET", "/v1/screen/status"); XCTAssertEqual(anon.status, 401)
    }

    func testAnotherDeviceDoesNotShareTheScope() async throws {
        grant()
        let other = try await h.pairDevice(name: "Second phone")
        let reply = try await h.request("GET", "/v1/screen/status", token: other.token)
        XCTAssertEqual(reply.status, 403)
    }

    // S4
    func testThe201stScreenRequestInAnHourIs429() async throws {
        grant()
        for index in 0..<RemoteService.screenPerHour {
            // The general limit allows 20 at once and 5 a second after that. Stay below it.
            h.clock.advance(0.25)
            let reply = try await get("/v1/screen/status")
            XCTAssertEqual(reply.status, 200, "request \(index + 1)")
            if reply.status != 200 { return }
        }
        h.clock.advance(0.25)
        let limited = try await get("/v1/screen/status")
        XCTAssertEqual(limited.status, 429)
        XCTAssertNotNil(limited.headers["retry-after"])
        // The limit is per device and per hour.
        let other = try await h.pairDevice(name: "Second phone")
        h.service.setScreenAccess(other.deviceID, granted: true)
        let second = try await h.request("GET", "/v1/screen/status", token: other.token); XCTAssertEqual(second.status, 200)
        h.clock.advance(3600)
        let again = try await code("/v1/screen/status"); XCTAssertEqual(again, 200)
    }

    // S6
    func testEveryScreenReadIsLoggedAndCountedForTheDevice() async throws {
        try ingest(["hello world"])
        _ = try await get("/v1/screen/status")
        XCTAssertEqual(h.service.screenReadsToday(deviceID), 0, "a refused request is not a read")
        grant()
        _ = try await get("/v1/screen/status")
        _ = try await get("/v1/screen/changes?since=today")
        _ = try await get("/v1/screen/search?q=hello")
        let search = try decode(RemoteScreenSearch.self, try await get("/v1/screen/search?q=hello").data)
        _ = try await get("/v1/screen/captures/\(try XCTUnwrap(search.hits.first).id)")
        _ = try await get("/v1/screen/search")
        XCTAssertEqual(h.service.screenReadsToday(deviceID), 5, "the 400 is not counted")
        let rows = h.service.store.accessLog().filter { $0.route.hasPrefix("/v1/screen/") && $0.status == 200 }
        XCTAssertEqual(Set(rows.map(\.route)), ["/v1/screen/status", "/v1/screen/changes", "/v1/screen/search", "/v1/screen/captures/:id"])
        XCTAssertTrue(rows.allSatisfy { $0.deviceID == deviceID })
        // Neither the query nor the screen text reaches the log.
        let log = h.service.store.accessLog().map { "\($0.route) \($0.method)" }.joined(separator: "\n")
        XCTAssertFalse(log.contains("hello"))
        // Yesterday's reads do not count today.
        h.clock.advance(2 * 86_400)
        XCTAssertEqual(h.service.screenReadsToday(deviceID), 0)
    }
}
