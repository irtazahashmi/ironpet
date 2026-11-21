import XCTest
@testable import IronPet
@testable import IronPetCore

/// The automation, meeting and settings routes of the remote API over a real listener and in-memory stores.
@MainActor
final class RemotePhaseFourTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var token = ""
    private var deviceID = ""
    private var root: URL!
    private var library: MeetingLibrary!
    private var recorder: FakeMeetingRecorder!
    private var config: ConfigStore!
    private var chat: ChatSession!
    private var turns: [ACPTurn] = []
    private var notices: [AutomationNotice] = []
    private var autoApprove = false
    private var previousThreads: URL!

    private func shell(_ id: String, by: String) -> Automation {
        Automation(id: id, name: id, enabled: true, trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "shell", command: "echo hi"), createdBy: by)
    }

    private func reminder(_ id: String) -> Automation {
        Automation(id: id, name: id, enabled: true, trigger: .init(type: "interval", minutes: 45, clock: "wall"),
                   action: .init(type: "bubble", title: "\(id) title", body: "\(id) body"), createdBy: "user")
    }

    override func setUp() async throws {
        TestMemory.isolate()
        previousThreads = ThreadStore.directory
        ThreadStore.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-p4-threads-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-p4-meetings-\(UUID().uuidString)")
        try makeMeeting("2026-11-14-1400", summary: "## Summary\nPlanned the launch.\n", transcript: "# Meeting\n[14:00:00] Me: hello secret-word\n", audio: true)
        try makeMeeting("2026-11-15-1000", summary: nil, transcript: "# Meeting\n[10:00:00] Me: second\n", audio: false)
        library = MeetingLibrary(root: root)
        library.regenerator.summarize = { _, _, _ in "## Summary\nRebuilt.\n" }
        recorder = FakeMeetingRecorder()
        config = ConfigStore(memory: Config())
        chat = ChatSession(restore: false)
        chat.workspace = FileManager.default.temporaryDirectory
        turns = []
        chat.turnRunner = { [unowned self] turn, _ in turns.append(turn) }
        notices = []
        autoApprove = false
        h = RemoteServerHarness(chat: chat, automations: [shell("backup", by: "user"), reminder("water")], meeting: recorder, meetingLibrary: library,
                                config: config, usage: UsageStore(database: APITestSupport.memoryDatabase()),
                                configureAutomations: { [unowned self] service in
                                    service.notice = { notices.append($0) }
                                    service.autoApproveEnabled = { autoApprove }
                                })
        h.api.meetings.reload()
        try await h.start()
        // The controller closes a listener the settings do not ask for, and every settings change makes it look. Ask for this one.
        config.update { $0.remote.enabled = true; $0.remote.port = h.port }
        await h.controller.settled()
        let paired = try await h.pairDevice()
        token = paired.token
        deviceID = paired.deviceID
    }

    override func tearDown() async throws {
        await h.stop()
        ThreadStore.directory = previousThreads
        try? FileManager.default.removeItem(at: root)
    }

    private func makeMeeting(_ name: String, summary: String?, transcript: String?, audio: Bool) throws {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let summary { try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8) }
        if let transcript { try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8) }
        if audio {
            for chunk in ["mic-000.wav", "them-000.wav"] { try Data("RIFFfake".utf8).write(to: folder.appendingPathComponent(chunk)) }
        }
    }

    private func get(_ path: String) async throws -> RemoteReply { try await h.request("GET", path, token: token) }
    private func post(_ path: String, _ body: [String: Any] = [:]) async throws -> RemoteReply { try await h.request("POST", path, token: token, body: body) }
    private func patch(_ path: String, _ body: [String: Any]) async throws -> RemoteReply { try await h.request("PATCH", path, token: token, body: body) }
    private func delete(_ path: String) async throws -> RemoteReply { try await h.request("DELETE", path, token: token) }

    // MARK: Automations

    // S1
    func testAShellAutomationFromThePhoneWaitsForApproveEvenWithAutoApproveOn() async throws {
        autoApprove = true
        var seen: [APIEvent] = []
        h.events.subscribe { seen.append($0) }
        let created = try await post("/v1/automations", ["name": "Disk check", "trigger": ["type": "interval", "minutes": 30, "clock": "wall"],
                                                          "action": ["type": "shell", "command": "df -h"]])
        XCTAssertEqual(created.status, 201, String(decoding: created.data, as: UTF8.self))
        XCTAssertEqual(created.json["created_by"] as? String, "remote:\(deviceID)")
        XCTAssertEqual(created.json["approval"] as? String, "pending")
        XCTAssertEqual(created.json["approval_detail"] as? String, "df -h")
        let bubble = try XCTUnwrap(notices.first { $0.id == AutomationService.approvalID("disk-check") }, "no approval bubble")
        XCTAssertTrue(bubble.macOnly)
        XCTAssertTrue(seen.contains { $0.kind == .automationNeedsApproval && $0.id == "disk-check" }, "the phone hears that it waits")
        XCTAssertTrue(bubble.buttons.contains { $0.title == "Approve" })
        XCTAssertFalse(notices.contains { $0.id.hasPrefix("automation-auto-approved") })
        // An agent on the Mac is still approved, so the rule is about the phone alone.
        _ = try h.api.automations.create(CreateAutomationRequest(
            definition: #"{"name": "Agent job", "trigger": {"type": "interval", "minutes": 30, "clock": "wall"}, "action": {"type": "shell", "command": "ls"}}"#,
            by: "agent:ghost"))
        XCTAssertNil(try h.api.automations.status("agent-job").approval)
        // The phone cannot approve: no route does.
        for path in ["/v1/automations/disk-check/approve", "/v1/automations/disk-check/reject"] {
            let reply = try await post(path)
            XCTAssertEqual(reply.status, 404, path)
        }
        XCTAssertEqual(try h.api.automations.status("disk-check").approval, .pending)
    }

    // S2
    func testChangingTheScheduleKeepsApprovalAndChangingTheCommandAsksAgain() async throws {
        let before = try await get("/v1/automations/backup")
        XCTAssertNil(before.json["approval"])
        let schedule = try await patch("/v1/automations/backup", ["trigger": ["minutes": 90]])
        XCTAssertEqual(schedule.status, 200, String(decoding: schedule.data, as: UTF8.self))
        XCTAssertEqual(schedule.json["created_by"] as? String, "user")
        XCTAssertNil(schedule.json["approval"])
        let command = try await patch("/v1/automations/backup", ["action": ["command": "rm -rf ~/x"]])
        XCTAssertEqual(command.status, 200)
        XCTAssertEqual(command.json["created_by"] as? String, "remote:\(deviceID)")
        XCTAssertEqual(command.json["approval"] as? String, "pending")
        XCTAssertNotNil(notices.first { $0.id == AutomationService.approvalID("backup") })
        // A body that claims another author does not change who the author is.
        let spoof = try await patch("/v1/automations/backup", ["createdBy": "user", "name": "Backup"])
        XCTAssertEqual(spoof.json["created_by"] as? String, "remote:\(deviceID)")
        XCTAssertEqual(spoof.json["approval"] as? String, "pending")
    }

    func testListDetailPauseResumeRunNowHistoryLogAndDelete() async throws {
        let list = try await get("/v1/automations")
        let items = try XCTUnwrap(list.json["automations"] as? [[String: Any]])
        XCTAssertEqual(Set(items.compactMap { $0["id"] as? String }), ["backup", "water"])
        let detail = try await get("/v1/automations/water")
        XCTAssertEqual(detail.json["name"] as? String, "water")
        XCTAssertTrue((detail.json["definition"] as? String ?? "").contains("water title"))
        let paused = try await post("/v1/automations/water/pause")
        XCTAssertEqual(paused.json["enabled"] as? Bool, false)
        let resumed = try await post("/v1/automations/water/resume")
        XCTAssertEqual(resumed.json["enabled"] as? Bool, true)
        let ran = try await post("/v1/automations/water/run-now")
        XCTAssertEqual(ran.json["status"] as? String, "started")
        let history = try await get("/v1/automations/water/history")
        XCTAssertEqual(history.status, 200)
        let log = try await get("/v1/automations/water/log")
        XCTAssertEqual(log.status, 200)
        XCTAssertNotNil(log.json["log"] as? [Any])
        let missing = try await get("/v1/automations/nope")
        XCTAssertEqual(missing.status, 404)
        let gone = try await delete("/v1/automations/water")
        XCTAssertEqual(gone.status, 200)
        XCTAssertEqual(h.api.automations.list().map(\.id), ["backup"])
        let invalid = try await post("/v1/automations", ["name": "Broken"])
        XCTAssertEqual(invalid.status, 400)
    }

    func testNewAutomationRequestGoesToTheChatWithTheMacsInstructions() async throws {
        let reply = try await post("/v1/automations/request", ["text": "tell me when CI breaks"])
        XCTAssertEqual(reply.status, 200)
        for _ in 0..<10 { await Task.yield() }
        let prompt = try XCTUnwrap(turns.first?.prompt)
        XCTAssertTrue(prompt.contains("tell me when CI breaks"))
        XCTAssertTrue(prompt.contains("new ironpet automation"))
        let empty = try await post("/v1/automations/request", ["text": "  "])
        XCTAssertEqual(empty.status, 400)
    }

    // MARK: Meetings

    // S4
    func testSummaryAndTranscriptComeAsTextAndNoRouteServesAudio() async throws {
        let list = try await get("/v1/meetings")
        let meetings = try XCTUnwrap(list.json["meetings"] as? [[String: Any]])
        XCTAssertEqual(meetings.compactMap { $0["id"] as? String }, ["2026-11-15-1000", "2026-11-14-1400"])
        XCTAssertEqual(meetings[1]["has_audio"] as? Bool, true)
        let summary = try await get("/v1/meetings/2026-11-14-1400/summary")
        XCTAssertEqual(summary.json["text"] as? String, "## Summary\nPlanned the launch.\n")
        let transcript = try await get("/v1/meetings/2026-11-14-1400/transcript")
        XCTAssertEqual(transcript.json["text"] as? String, "# Meeting\n[14:00:00] Me: hello secret-word\n")
        let none = try await get("/v1/meetings/2026-11-15-1000/summary")
        XCTAssertEqual(none.status, 404)
        for path in ["mic-000.wav", "them-000.wav", "audio", "audio/mic-000.wav", "../2026-11-14-1400/mic-000.wav"] {
            let reply = try await get("/v1/meetings/2026-11-14-1400/\(path)")
            XCTAssertEqual(reply.status, 404, path)
            XCTAssertFalse(String(decoding: reply.data, as: UTF8.self).contains("RIFF"), path)
        }
        let escape = try await get("/v1/meetings/..%2F..%2Fetc/transcript")
        XCTAssertEqual(escape.status, 404)
    }

    // S5
    func testNoRouteStartsARecordingAndStopReachesTheRecorder() async throws {
        for path in ["/v1/meetings/start", "/v1/meetings/record", "/v1/meetings/2026-11-14-1400/start"] {
            let reply = try await post(path)
            XCTAssertEqual(reply.status, 404, path)
        }
        let idle = try await post("/v1/meetings/stop")
        XCTAssertEqual(idle.status, 409)
        XCTAssertEqual(recorder.calls, [])
        recorder.isRecording = true
        recorder.phase = .recording
        recorder.appName = "Zoom"
        let state = try await get("/v1/meetings/state")
        XCTAssertEqual(state.json["phase"] as? String, "recording")
        XCTAssertEqual(state.json["app_name"] as? String, "Zoom")
        let stopped = try await post("/v1/meetings/stop")
        XCTAssertEqual(stopped.status, 200)
        XCTAssertEqual(recorder.calls, ["stop"])
        XCTAssertFalse(recorder.calls.contains("start"))
    }

    func testRegenerateAskAndDelete() async throws {
        let bad = try await post("/v1/meetings/2026-11-14-1400/regenerate?mode=nope")
        XCTAssertEqual(bad.status, 400)
        let blocked = try await post("/v1/meetings/2026-11-15-1000/regenerate?mode=full")
        XCTAssertEqual(blocked.status, 409, "a full rebuild needs the audio")
        let started = try await post("/v1/meetings/2026-11-14-1400/regenerate?mode=summary")
        XCTAssertEqual(started.status, 202)
        for _ in 0..<200 {
            if (try? String(contentsOf: root.appendingPathComponent("2026-11-14-1400/summary.md"), encoding: .utf8))?.contains("Rebuilt") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let rebuilt = try await get("/v1/meetings/2026-11-14-1400/summary")
        XCTAssertEqual(rebuilt.json["text"] as? String, "## Summary\nRebuilt.\n")
        let unwired = try await post("/v1/meetings/2026-11-14-1400/ask")
        XCTAssertEqual(unwired.status, 503)
        var files: [URL] = []
        h.api.meetings.askHandler = { files = $0 }
        let asked = try await post("/v1/meetings/2026-11-14-1400/ask")
        XCTAssertEqual(asked.status, 200)
        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.allSatisfy { $0.pathExtension == "md" })
        let missing = try await delete("/v1/meetings/nope")
        XCTAssertEqual(missing.status, 404)
    }

    // MARK: Settings

    // S3
    func testAPatchOfAForbiddenKeyIs403AndChangesNothing() async throws {
        let before = config.config
        for patch: [String: Any] in [["voice": ["baseUrl": "https://evil.example/v1"]], ["meetings": ["enabled": true]], ["screenCapture": ["enabled": true]],
                                     ["remote": ["enabled": false]], ["telegram": ["enabled": true]], ["automations": ["autoApprove": true]],
                                     ["integrations": ["shareMCPSignIns": true]], ["hotkeys": ["chat": ""]], ["editors": []], ["skills": ["autoUpdate": false]],
                                     ["nope": 1], ["reminders": 5]] {
            let reply = try await self.patch("/v1/settings", patch)
            XCTAssertEqual(reply.status, 403, "\(patch)")
            XCTAssertEqual(config.config, before, "\(patch)")
        }
        // One bad key in a patch refuses the whole patch.
        let mixed = try await patch("/v1/settings", ["reminders": ["paused": true], "voice": ["baseUrl": "https://evil.example/v1"]])
        XCTAssertEqual(mixed.status, 403)
        XCTAssertEqual(config.config, before)
    }

    func testAnAllowedKeyIsSavedAndTheSwitchesCanOnlyGoOff() async throws {
        let saved = try await patch("/v1/settings", ["reminders": ["paused": true, "water": ["minutes": 30]], "pet": ["name": "Boo"]])
        XCTAssertEqual(saved.status, 200, String(decoding: saved.data, as: UTF8.self))
        XCTAssertTrue(config.config.reminders.paused)
        XCTAssertEqual(config.config.reminders.water.minutes, 30)
        XCTAssertEqual(config.config.pet.name, "Boo")
        XCTAssertEqual((saved.json["reminders"] as? [String: Any])?["paused"] as? Bool, true)
        config.update { $0.meetings.enabled = true; $0.screenCapture.enabled = true }
        let off = try await patch("/v1/settings", ["meetings": ["enabled": false], "screenCapture": ["enabled": false]])
        XCTAssertEqual(off.status, 200)
        XCTAssertFalse(config.config.meetings.enabled)
        XCTAssertFalse(config.config.screenCapture.enabled)
        let wrongType = try await patch("/v1/settings", ["reminders": ["paused": "yes"]])
        XCTAssertEqual(wrongType.status, 400)
        let sprite = try await patch("/v1/settings", ["pet": ["sprite": "/etc/passwd"]])
        XCTAssertEqual(sprite.status, 403)
    }

    func testReadingSettingsLeavesOutWhereDataGoes() async throws {
        config.update { $0.voice.baseUrl = "https://voice.example/v1"; $0.telegram.enabled = true; $0.remote.machineName = "Secret Mac" }
        let reply = try await get("/v1/settings")
        XCTAssertEqual(reply.status, 200)
        let text = String(decoding: reply.data, as: UTF8.self)
        for word in ["baseUrl", "voice.example", "telegram", "remote", "Secret Mac", "autoApprove", "hotkeys", "integrations"] {
            XCTAssertFalse(text.contains(word), word)
        }
        XCTAssertEqual((reply.json["pet"] as? [String: Any])?["name"] as? String, "Ghost")
    }

    func testPetGalleryUsageAndOpaqueIds() async throws {
        let pets = try await get("/v1/settings/pets")
        XCTAssertEqual(pets.status, 200)
        let list = try XCTUnwrap(pets.json["pets"] as? [[String: Any]])
        for pet in list { XCTAssertFalse((pet["id"] as? String ?? "").contains("/")) }
        let unknown = try await post("/v1/settings/pet", ["id": "nope"])
        XCTAssertEqual(unknown.status, 404)
        let usage = try await get("/v1/usage?range=7d")
        XCTAssertEqual(usage.status, 200)
        XCTAssertEqual(usage.json["days"] as? Int, 7)
        let bad = try await get("/v1/usage?range=0d")
        XCTAssertEqual(bad.status, 400)
    }

    // S8
    func testEveryNewRouteNeedsAValidTokenAndTheLogKeepsOnlyTheTemplate() async throws {
        let routes: [(String, String)] = [
            ("GET", "/v1/automations"), ("POST", "/v1/automations"), ("POST", "/v1/automations/request"), ("GET", "/v1/automations/backup"),
            ("PATCH", "/v1/automations/backup"), ("DELETE", "/v1/automations/backup"), ("GET", "/v1/automations/backup/history"),
            ("GET", "/v1/automations/backup/log"), ("POST", "/v1/automations/backup/pause"), ("POST", "/v1/automations/backup/resume"),
            ("POST", "/v1/automations/backup/run-now"), ("GET", "/v1/meetings"), ("GET", "/v1/meetings/state"), ("POST", "/v1/meetings/stop"),
            ("GET", "/v1/meetings/2026-11-14-1400/summary"), ("GET", "/v1/meetings/2026-11-14-1400/transcript"),
            ("POST", "/v1/meetings/2026-11-14-1400/regenerate"), ("POST", "/v1/meetings/2026-11-14-1400/ask"), ("DELETE", "/v1/meetings/2026-11-14-1400"),
            ("GET", "/v1/settings"), ("PATCH", "/v1/settings"), ("GET", "/v1/settings/pets"), ("POST", "/v1/settings/pet"), ("GET", "/v1/usage"),
        ]
        for (method, path) in routes {
            let none = try await h.request(method, path, body: method == "GET" || method == "DELETE" ? nil : [:])
            XCTAssertEqual(none.status, 401, "\(method) \(path) without a token")
            h.clock.advance(70)
            let wrong = try await h.request(method, path, token: "ipt_wrong", body: method == "GET" || method == "DELETE" ? nil : [:])
            XCTAssertEqual(wrong.status, 401, "\(method) \(path) with a wrong token")
            h.clock.advance(70)
        }
        h.service.revoke(deviceID)
        let revoked = try await h.request("GET", "/v1/meetings/2026-11-14-1400/transcript", token: token)
        XCTAssertEqual(revoked.status, 401)
    }

    func testTheAccessLogHasRouteTemplatesAndNoTextFromTheCall() async throws {
        _ = try await get("/v1/meetings/2026-11-14-1400/transcript")
        _ = try await get("/v1/automations/backup/log?secret=q1")
        _ = try await patch("/v1/settings", ["pet": ["name": "Mx-private-name"]])
        _ = try await post("/v1/automations/request", ["text": "private request text"])
        let rows = h.service.store.accessLog(limit: 50)
        let routes = Set(rows.map(\.route))
        XCTAssertTrue(routes.contains("/v1/meetings/:id/transcript"))
        XCTAssertTrue(routes.contains("/v1/automations/:id/log"))
        XCTAssertTrue(routes.contains("/v1/settings"))
        XCTAssertTrue(routes.contains("/v1/automations/request"))
        let dump = try h.database.read { try $0.rows("SELECT * FROM remote_access_log") }.flatMap { $0 }.map { "\($0 ?? "")" }.joined(separator: "\n")
        for word in ["2026-11-14-1400", "secret-word", "q1", "Mx-private-name", "private request text", "backup"] {
            XCTAssertFalse(dump.contains(word), word)
        }
    }
}
