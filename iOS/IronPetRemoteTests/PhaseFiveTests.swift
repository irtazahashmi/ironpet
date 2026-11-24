import IronPetKit
import SwiftUI
import XCTest
@testable import IronPetRemote

private func waitUntil(_ timeout: Double = 30, _ condition: @escaping @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private final class ScreenAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String] = []
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }
    func authenticate(reason: String) async -> Bool {
        lock.lock(); _asked.append(reason); lock.unlock()
        return true
    }
}

@MainActor
final class PhaseFiveTests: XCTestCase {
    var server: MockIronPetServer!
    private var auth: ScreenAuthenticator!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        auth = ScreenAuthenticator()
        now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDown() async throws { server.stop() }

    private func model() -> ScreenModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let gate = TranscriptGate(authenticator: auth, reason: "Show screen text", now: { [unowned self] in now })
        return ScreenModel(client: client, events: events, gate: gate, onUnauthorized: {})
    }

    private func screenRequests() -> Int { server.requests.filter { $0.path.hasPrefix("/v1/screen/") }.count }

    func testNothingIsReadBeforeTheUnlockAndTheAskNamesTheScreen() async throws {
        let model = model()
        model.start()
        await waitUntil { model.loaded }
        XCTAssertFalse(model.gate.isUnlocked)
        XCTAssertEqual(screenRequests(), 0)
        let locked = await model.capture(12)
        XCTAssertNil(locked)
        await model.search("release")
        XCTAssertEqual(screenRequests(), 0)
        await model.unlock()
        XCTAssertEqual(auth.asked, ["Show screen text"])
        XCTAssertEqual(model.windows.count, 2)
        XCTAssertEqual(model.status?.captureCount, 42)
        model.stop()
    }

    func testAFailedChangeListShowsTheErrorNotTheEmptyState() async throws {
        server.brokenRoutes = ["/v1/screen/changes": 500]
        let model = model()
        await model.unlock()
        XCTAssertNotNil(model.status, "the status call after it worked")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.showsEmptyState)

        server.brokenRoutes = [:]
        await model.refresh()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.windows.count, 2)
    }

    func testACancelledFirstLoadShowsNoErrorAndNoEmptyState() async throws {
        let model = model()
        await model.gate.unlock()
        let first = Task { await model.refresh() }
        first.cancel()
        await first.value
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.showsEmptyState)
        XCTAssertFalse(model.loaded)

        await model.refresh()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.showsEmptyState)
        XCTAssertEqual(model.windows.count, 2)
    }

    func testAFailedStatusKeepsItsErrorWhenTheChangeListWorks() async throws {
        server.brokenRoutes = ["/v1/screen/status": 200]
        let model = model()
        await model.unlock()
        XCTAssertEqual(model.windows.count, 2)
        XCTAssertNotNil(model.errorMessage, "an undecodable status is shown, not cleared by the list that followed")
    }

    func testAScreenWithNoChangesShowsTheEmptyState() async throws {
        server.screenWindows = []
        let model = model()
        await model.unlock()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.showsEmptyState)
    }

    func testLockingDropsEveryScreenTextFromMemory() async throws {
        let model = model()
        await model.unlock()
        await model.search("release")
        _ = await model.capture(12)
        XCTAssertFalse(model.hits.isEmpty)
        XCTAssertNotNil(model.captures[12])
        model.gate.lock()
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(model.captures.isEmpty)
        XCTAssertNil(model.status)
        XCTAssertNil(model.searched)
    }

    func testTheScreenLocksAfterFiveMinutesInTheBackground() async throws {
        let model = model()
        await model.unlock()
        model.gate.appMovedToBackground()
        now = now.addingTimeInterval(4 * 60)
        model.gate.appBecameActive()
        XCTAssertTrue(model.gate.isUnlocked, "four minutes is not enough to lock")
        model.gate.appMovedToBackground()
        now = now.addingTimeInterval(5 * 60)
        model.gate.appBecameActive()
        XCTAssertFalse(model.gate.isUnlocked)
        XCTAssertTrue(model.windows.isEmpty)
    }

    func testAMacWithoutTheScopeShowsTheForbiddenState() async throws {
        server.screenAllowed = false
        let model = model()
        await model.unlock()
        XCTAssertTrue(model.forbidden)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.windows.isEmpty)
        server.screenAllowed = true
        await model.refresh()
        XCTAssertFalse(model.forbidden)
        XCTAssertEqual(model.windows.count, 2)
    }

    func testPausingAndChangingTheRangeGoToTheMac() async throws {
        let model = model()
        await model.unlock()
        await model.setRange(.threeDays)
        XCTAssertTrue(try XCTUnwrap(server.requests.last { $0.path == "/v1/screen/changes" }).query.contains("since=3d"))
        await model.pause(minutes: 15)
        XCTAssertEqual(model.status?.paused, true)
        XCTAssertEqual(try XCTUnwrap(server.requests.last { $0.path == "/v1/screen/pause" }).json["minutes"] as? Int, 15)
        XCTAssertNotNil(model.notice)
    }

    func testTheContentIsCoveredWheneverTheAppIsNotActive() {
        XCTAssertTrue(ScreenPrivacyCover.isCovered(.inactive))
        XCTAssertTrue(ScreenPrivacyCover.isCovered(.background))
        XCTAssertFalse(ScreenPrivacyCover.isCovered(.active))
    }
}
