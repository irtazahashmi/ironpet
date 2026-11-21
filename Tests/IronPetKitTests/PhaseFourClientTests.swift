import XCTest
@testable import IronPetKit

/// The phase 4 client calls and DTOs against the mock Mac.
final class PhaseFourClientTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    func testAutomationsDecodeWithTheApprovalState() async throws {
        let list = try await client().automations()
        XCTAssertEqual(list.map(\.id), ["water", "ci-watch"])
        XCTAssertFalse(list[0].waitsForApproval)
        XCTAssertTrue(list[1].waitsForApproval)
        XCTAssertEqual(list[0].lastRun?.outcome, "ok")
        let detail = try await client().automation(id: "water")
        XCTAssertNotNil(detail.definition)
        let history = try await client().automationHistory(id: "water")
        XCTAssertEqual(history.count, 1)
        let log = try await client().automationLog(id: "water")
        XCTAssertEqual(log.first?.summary, "shown")
        do { _ = try await client().automation(id: "nope"); XCTFail("found a missing automation") } catch ClientError.api(let status, _, _) {
            XCTAssertEqual(status, 404)
        }
    }

    func testCreateAndUpdateSendJSONObjectsAndRejectOtherText() async throws {
        let made = try await client().createAutomation(definition: #"{"name": "Disk", "action": {"type": "shell", "command": "df"}}"#)
        XCTAssertTrue(made.waitsForApproval)
        XCTAssertEqual(made.createdBy, "remote:device-1")
        let sent = try XCTUnwrap(server.requests.last { $0.line == "POST /v1/automations" })
        XCTAssertEqual((sent.json["action"] as? [String: Any])?["command"] as? String, "df")
        let changed = try await client().updateAutomation(id: "water", changes: #"{"name": "Water"}"#)
        XCTAssertEqual(changed.name, "Water")
        do { _ = try await client().createAutomation(definition: "[1]"); XCTFail("sent an array") } catch ClientError.api(let status, _, _) {
            XCTAssertEqual(status, 400)
        }
    }

    func testMeetingsStateTextAndStop() async throws {
        let list = try await client().meetings()
        XCTAssertEqual(list.first?.hasAudio, false)
        XCTAssertEqual(list.last?.hasAudio, true)
        let transcript = try await client().meetingTranscript(id: "2026-11-14-1400")
        XCTAssertTrue(transcript.contains("secret-word"))
        do { _ = try await client().meetingSummary(id: "2026-11-15-1000"); XCTFail("read a missing summary") } catch ClientError.api(let status, _, _) {
            XCTAssertEqual(status, 404)
        }
        do { try await client().stopMeeting(); XCTFail("stopped nothing") } catch ClientError.api(let status, _, _) {
            XCTAssertEqual(status, 409)
        }
        server.meetingState = RemoteMeetingState(phase: "recording", appName: "Zoom")
        let state = try await client().meetingState()
        XCTAssertTrue(state.isRecording)
        try await client().stopMeeting()
        try await client().regenerateMeeting(id: "2026-11-14-1400", summaryOnly: false)
        XCTAssertEqual(server.requests.last?.query, "mode=full")
    }

    func testSettingsAreCamelCaseAndAForbiddenPatchIsAnError() async throws {
        let config = try await client().settings()
        XCTAssertEqual(config.pet.name, "Ghost")
        XCTAssertTrue(config.meetings.enabled)
        let saved = try await client().patchSettings(["reminders": ["paused": true]])
        XCTAssertTrue(saved.reminders.paused)
        let body = try XCTUnwrap(server.requests.last { $0.method == "PATCH" }).json
        XCTAssertEqual((body["reminders"] as? [String: Any])?["paused"] as? Bool, true)
        do { _ = try await client().patchSettings(["voice": ["baseUrl": "x"]]); XCTFail("changed a forbidden key") } catch ClientError.api(let status, let code, _) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(code, "forbidden")
        }
        let encoded = try WireJSON.makeEncoder().encode(config)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("welcomeBack"))
    }

    func testTheClientKeepsNoResponseCacheOnDisk() {
        // An ephemeral session caches in memory at most, so a transcript the Mac sent is never written to disk by URLSession.
        XCTAssertEqual(client().session.configuration.urlCache?.diskCapacity ?? 0, 0)
    }
}
