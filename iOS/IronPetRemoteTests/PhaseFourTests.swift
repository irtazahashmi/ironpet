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

/// Answers the Face ID prompt the way a test says, and counts the prompts.
private final class FakeAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _answer = true
    private var _asked = 0
    var answer: Bool { get { lock.lock(); defer { lock.unlock() }; return _answer } set { lock.lock(); _answer = newValue; lock.unlock() } }
    var asked: Int { lock.lock(); defer { lock.unlock() }; return _asked }
    func authenticate(reason: String) async -> Bool {
        lock.lock(); _asked += 1; let value = _answer; lock.unlock()
        return value
    }
}

@MainActor
final class PhaseFourTests: XCTestCase {
    var server: MockIronPetServer!
    private var auth: FakeAuthenticator!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        auth = FakeAuthenticator()
        now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDown() async throws { server.stop() }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    private func events(_ client: IronPetClient) -> SharedEventSource {
        SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
    }

    private func meetings() -> MeetingsModel {
        let client = client()
        let gate = TranscriptGate(authenticator: auth, now: { [unowned self] in now })
        return MeetingsModel(client: client, events: events(client), gate: gate, onUnauthorized: {})
    }

    // MARK: Automations

    func testTheListShowsWhichAutomationsWaitForApproveAndTheEventReloads() async throws {
        let client = client()
        let model = AutomationsModel(client: client, events: events(client), onUnauthorized: {})
        model.start()
        await waitUntil { model.loaded }
        XCTAssertEqual(model.automations.map(\.id), ["water", "ci-watch"])
        XCTAssertEqual(model.automations.filter(\.waitsForApproval).map(\.id), ["ci-watch"])
        var changed = server.automations
        changed[0].approval = "pending"
        server.automations = changed
        server.publish(RemoteEvent.automationNeedsApproval, id: "water")
        await waitUntil { model.automations.filter(\.waitsForApproval).count == 2 }
        XCTAssertEqual(model.automations.filter(\.waitsForApproval).count, 2)
        model.stop()
    }

    func testPauseResumeRunNowDeleteAndCreateGoToTheMac() async throws {
        let client = client()
        let model = AutomationsModel(client: client, events: events(client), onUnauthorized: {})
        await model.refresh()
        let water = try XCTUnwrap(model.automations.first)
        await model.setPaused(water, true)
        XCTAssertEqual(server.count("POST /v1/automations/water/pause"), 1)
        XCTAssertFalse(try XCTUnwrap(model.automations.first { $0.id == "water" }).enabled)
        await model.setPaused(water, false)
        XCTAssertEqual(server.count("POST /v1/automations/water/resume"), 1)
        await model.runNow(water)
        XCTAssertEqual(server.count("POST /v1/automations/water/run-now"), 1)
        XCTAssertEqual(model.notice, "Started Drink water.")
        let created = await model.create(definition: #"{"name": "Disk check", "action": {"type": "shell", "command": "df"}}"#)
        XCTAssertTrue(created)
        XCTAssertEqual(model.notice, "Disk check waits for Approve on the Mac before it runs.")
        XCTAssertTrue(try XCTUnwrap(model.automations.first { $0.id == "disk-check" }).waitsForApproval)
        let notJSON = await model.create(definition: "nope")
        XCTAssertFalse(notJSON)
        XCTAssertNotNil(model.errorMessage)
        await model.delete(water)
        XCTAssertEqual(server.count("DELETE /v1/automations/water"), 1)
        XCTAssertNil(model.automations.first { $0.id == "water" })
        let asked = await model.request("tell me when CI breaks")
        XCTAssertTrue(asked)
        XCTAssertEqual(server.requests.last { $0.line == "POST /v1/automations/request" }?.json["text"] as? String, "tell me when CI breaks")
    }

    // MARK: Transcripts gate (S7)

    func testNothingIsReadFromTheMacBeforeTheUnlock() async throws {
        let model = meetings()
        model.start()
        await waitUntil { model.loaded }
        XCTAssertFalse(model.gate.isUnlocked)
        XCTAssertEqual(auth.asked, 0)
        XCTAssertEqual(server.count("GET /v1/meetings"), 0, "locked, so the list is not even requested")
        let locked = await model.text("2026-11-14-1400", "transcript")
        XCTAssertNil(locked)
        XCTAssertEqual(server.count("GET /v1/meetings/2026-11-14-1400/transcript"), 0)

        auth.answer = false
        await model.unlock()
        XCTAssertFalse(model.gate.isUnlocked)
        XCTAssertTrue(model.gate.refused)
        XCTAssertTrue(model.meetings.isEmpty)

        auth.answer = true
        await model.unlock()
        XCTAssertTrue(model.gate.isUnlocked)
        XCTAssertEqual(auth.asked, 2)
        XCTAssertEqual(model.meetings.map(\.id), ["2026-11-15-1000", "2026-11-14-1400"])
        let transcript = await model.text("2026-11-14-1400", "transcript")
        XCTAssertEqual(transcript, "# Meeting\n[14:00:00] Me: hello secret-word\n")
        model.stop()
    }

    func testFiveMinutesInTheBackgroundLockAgainAndDropTheText() async throws {
        let model = meetings()
        await model.unlock()
        _ = await model.text("2026-11-14-1400", "transcript")
        XCTAssertFalse(model.texts.isEmpty)

        // Four minutes away: still open.
        model.gate.appMovedToBackground()
        now = now.addingTimeInterval(4 * 60)
        model.gate.appBecameActive()
        XCTAssertTrue(model.gate.isUnlocked)
        XCTAssertFalse(model.texts.isEmpty)

        // Five minutes away: locked, and the text and the list are gone from memory.
        model.gate.appMovedToBackground()
        now = now.addingTimeInterval(5 * 60)
        model.gate.appBecameActive()
        XCTAssertFalse(model.gate.isUnlocked)
        XCTAssertTrue(model.texts.isEmpty)
        XCTAssertTrue(model.meetings.isEmpty)
        let after = await model.text("2026-11-14-1400", "transcript")
        XCTAssertNil(after)

        await model.unlock()
        XCTAssertEqual(auth.asked, 2, "the second look asks again")
        XCTAssertTrue(model.gate.isUnlocked)
    }

    /// The scene phase reaches the gate with no Meetings screen involved, which is how MainTabs drives it.
    func testScenePhaseChangesLockTheGateWithoutAnyScreen() async throws {
        let model = meetings()
        await model.unlock()
        model.gate.scenePhaseChanged(.inactive)
        model.gate.scenePhaseChanged(.background)
        now = now.addingTimeInterval(5 * 60)
        model.gate.scenePhaseChanged(.active)
        XCTAssertFalse(model.gate.isUnlocked)
    }

    /// The list fails and the state call after it works: the error must survive, and "No meetings" must not show.
    func testAFailedListShowsNoRowAndNotTheEmptyState() async throws {
        server.brokenRoutes = ["/v1/meetings": 500]
        let model = meetings()
        await model.unlock()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(server.count("GET /v1/meetings/state"), 1, "the state call after the failed list worked")
        XCTAssertNil(model.errorMessage, "a failed read shows no row")
        XCTAssertFalse(model.showsEmptyState)

        server.brokenRoutes = [:]
        await model.refresh()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.meetings.count, 2)
    }

    /// A cancelled first load (a restarted `.task`, a second reload) is no error and no empty list. The load after it fills the list.
    func testACancelledFirstLoadShowsNoErrorAndNoEmptyState() async throws {
        let model = meetings()
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
        XCTAssertEqual(model.meetings.count, 2)
    }

    func testAListTheClientCannotDecodeShowsNoRowAndNotTheEmptyState() async throws {
        server.brokenRoutes = ["/v1/meetings": 200]
        let model = meetings()
        await model.unlock()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.showsEmptyState)
    }

    func testAMacWithNoMeetingsShowsTheEmptyState() async throws {
        server.meetings = []
        let model = meetings()
        await model.unlock()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.showsEmptyState)
    }

    func testTextIsHeldInMemoryAndReadOnce() async throws {
        let model = meetings()
        await model.unlock()
        _ = await model.text("2026-11-14-1400", "summary")
        _ = await model.text("2026-11-14-1400", "summary")
        XCTAssertEqual(server.count("GET /v1/meetings/2026-11-14-1400/summary"), 1, "held in memory after the first read")
    }

    func testStopRecordingRebuildAskAndDeleteReachTheMac() async throws {
        let model = meetings()
        await model.unlock()
        var recording = RemoteMeetingState(phase: "recording", appName: "Zoom")
        recording.chunksDone = 2
        server.meetingState = recording
        await model.refresh()
        XCTAssertTrue(model.state.isRecording)
        await model.stopRecording()
        XCTAssertEqual(server.count("POST /v1/meetings/stop"), 1)
        XCTAssertFalse(model.state.isRecording)
        let meeting = try XCTUnwrap(model.meetings.last)
        await model.regenerate(meeting, summaryOnly: true)
        XCTAssertEqual(server.requests.last { $0.path.hasSuffix("/regenerate") }?.query, "mode=summary")
        await model.ask(meeting)
        XCTAssertEqual(server.count("POST /v1/meetings/2026-11-14-1400/ask"), 1)
        await model.delete(meeting)
        XCTAssertEqual(server.count("DELETE /v1/meetings/2026-11-14-1400"), 1)
        XCTAssertEqual(model.meetings.map(\.id), ["2026-11-15-1000"])
        // The app has no call that starts a recording.
        XCTAssertFalse(server.requests.contains { $0.path.contains("start") })
    }

    // MARK: Settings

    func testSettingsPatchPetAndUsage() async throws {
        let client = client()
        let model = PhoneSettingsModel(client: client, events: events(client), onUnauthorized: {})
        await model.refresh()
        XCTAssertEqual(model.config?.pet.name, "Ghost")
        XCTAssertEqual(model.pets.map(\.name), ["Ghost", "Fox"])
        XCTAssertEqual(model.usage?.rows.first?.requests, 12)
        await model.patch(["reminders": ["paused": true]])
        XCTAssertEqual(model.config?.reminders.paused, true)
        XCTAssertNil(model.errorMessage)
        await model.patch(["voice": ["baseUrl": "https://elsewhere.example"]])
        XCTAssertEqual(model.errorMessage, "\"voice.baseUrl\" cannot be changed from the phone")
        await model.select(try XCTUnwrap(model.pets.last))
        XCTAssertEqual(model.pets.first { $0.selected }?.name, "Fox")
        await model.patch(["meetings": ["enabled": false]])
        XCTAssertEqual(model.config?.meetings.enabled, false)
    }
}
