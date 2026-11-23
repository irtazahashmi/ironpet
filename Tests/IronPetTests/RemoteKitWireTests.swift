import XCTest
import IronPetKit
@testable import IronPet
@testable import IronPetCore

/// Every task and resource route of the remote API answers with JSON that decodes into its `IronPetKit` type and encodes back to the same
/// JSON, so the phone loses no field. The goldens spell out the JSON the routes sent before they encoded Kit types.
@MainActor
final class RemoteKitWireTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var token = ""
    private var sessions: SessionStore!
    private var signals: SignalStore!
    private var root: URL!

    override func setUp() async throws {
        TestMemory.isolate()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-kit-wire-\(UUID().uuidString)")
        for name in ["bundled", "pets", "backgrounds"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        sessions = SessionStore()
        signals = SignalStore()
        let chat = ChatSession(restore: false)
        chat.workspace = FileManager.default.temporaryDirectory
        chat.turnRunner = { _, _ in }
        h = RemoteServerHarness(sessions: sessions, signals: signals, chat: chat,
                                petAssets: MacPetAssets(library: root.appendingPathComponent("pets"), bundled: root.appendingPathComponent("bundled"),
                                                        backgrounds: root.appendingPathComponent("backgrounds")))
        try await h.start()
        token = try await h.pairDevice().token
    }

    override func tearDown() async throws {
        await h.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func get(_ path: String) async throws -> RemoteReply { try await h.request("GET", path, token: token) }
    private func post(_ path: String, _ body: [String: Any] = [:]) async throws -> RemoteReply { try await h.request("POST", path, token: token, body: body) }
    private func patch(_ path: String, _ body: [String: Any]) async throws -> RemoteReply { try await h.request("PATCH", path, token: token, body: body) }

    private let iso = ISO8601DateFormatter()

    /// Decodes the body into `T`, encodes it again the way the routes do and compares the two as JSON.
    @discardableResult
    private func lossless<T: Codable>(_ type: T.Type, _ reply: RemoteReply, _ route: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        XCTAssertTrue((200..<300).contains(reply.status), route, file: file, line: line)
        let value = try WireJSON.makeDecoder().decode(T.self, from: reply.data)
        let again = RemoteWire.object(value) as NSDictionary
        XCTAssertEqual(again, reply.json as NSDictionary, "\(route) loses a field between the wire and \(T.self)", file: file, line: line)
        return value
    }

    private func hook(_ name: String, session: String, payload: [String: Any] = [:], workspace: String = "/Users/me/web-app") {
        var payload = payload
        payload["session_id"] = session
        sessions.apply(HookEvent(source: .claude, name: name, payload: payload, origin: SessionOrigin(workspace: workspace)))
    }

    // MARK: Tasks

    func testTaskRoutesDecodeIntoKitTypesAndKeepTheirJSON() async throws {
        let due = Date(timeIntervalSince1970: 1_900_000_000)
        let item = try h.api.tasks.create(CreateTaskRequest(
            title: "Review the contract", notes: "Check clause 4", status: .needsYou, source: .agent, due: due,
            links: [TaskLink(kind: .url, ref: "https://example.com/c", label: "Contract"), TaskLink(kind: .file, ref: "/tmp/c.pdf")],
            waitingOn: nil, sourceRef: nil, labels: ["team": "legal"], by: "test"))
        let plain = try h.api.tasks.create(CreateTaskRequest(title: "Bare", source: .user))

        let list = try await get("/v1/tasks?include_done=1")
        let tasks = try lossless(TaskListResponse.self, list, "GET /v1/tasks").tasks
        XCTAssertEqual(Set(tasks.map(\.id)), [item.id, plain.id])

        let created = iso.string(from: item.created), updated = iso.string(from: item.updated)
        let golden: [String: Any] = [
            "id": item.id, "title": "Review the contract", "notes": "Check clause 4", "status": "needs_you", "source": "agent",
            "created": created, "updated": updated, "due": iso.string(from: due), "labels": ["team": "legal"],
            "links": [["kind": "url", "ref": "https://example.com/c", "label": "Contract"], ["kind": "file", "ref": "/tmp/c.pdf"]],
            "history": [["at": iso.string(from: h.api.tasks.history(item.id)[0].at), "by": "test", "kind": h.api.tasks.history(item.id)[0].kind.rawValue,
                         "detail": h.api.tasks.history(item.id)[0].detail]],
        ]
        let detail = try await get("/v1/tasks/\(item.id)")
        try lossless(RemoteTaskDetail.self, detail, "GET /v1/tasks/<id>")
        XCTAssertEqual(detail.json as NSDictionary, golden as NSDictionary)

        let bare = try await get("/v1/tasks/\(plain.id)")
        XCTAssertEqual(Set(bare.json.keys), ["id", "title", "status", "source", "created", "updated", "history"], "empty fields stay off the wire")

        let made = try await post("/v1/tasks", ["title": "From the phone", "notes": "n", "status": "in_progress", "due": "2030-01-02T03:04:05Z",
                                                "links": [["kind": "url", "ref": "https://x.test"]], "labels": ["a": "b"], "waiting_on": "Ana"])
        XCTAssertEqual(made.status, 201)
        try lossless(RemoteTask.self, made, "POST /v1/tasks")
        XCTAssertEqual(made.json["waiting_on"] as? String, "Ana")
        let id = try XCTUnwrap(made.json["id"] as? String)
        let changed = try await patch("/v1/tasks/\(id)", ["title": "Renamed", "note": "why"])
        try lossless(RemoteTask.self, changed, "PATCH /v1/tasks/<id>")
        XCTAssertEqual(changed.json["title"] as? String, "Renamed")
        let closed = try await post("/v1/tasks/\(id)/close", ["note": "merged"])
        try lossless(RemoteTask.self, closed, "POST /v1/tasks/<id>/close")
        XCTAssertEqual(closed.json["status"] as? String, "done")
        XCTAssertNotNil(closed.json["closed"])
        let deleted = try await h.request("DELETE", "/v1/tasks/\(id)", token: token)
        XCTAssertEqual(deleted.json as NSDictionary, ["deleted": id] as NSDictionary)
    }

    func testQuickFilterRoutesServeTheChipsAndRemoveOne() async throws {
        // Filters live in config.json, so saving one fires settings.changed and the controller matches the server to the settings.
        // Turn the remote API on at the port the harness listens on first, so that match leaves the server as it is.
        let port = h.port
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = port }
        await h.controller.settled()
        try h.api.tasks.upsertQuickFilter(id: nil, name: "Epic", query: ["label": ["project": "epic"]])
        try h.api.tasks.upsertQuickFilter(id: nil, name: "Needs me", query: ["status": "needs_you"])
        await h.controller.settled()
        let none = try await h.request("GET", "/v1/task-filters")
        XCTAssertEqual(none.status, 401, "device token auth, like the other routes")
        let list = try await get("/v1/task-filters")
        let decoded = try lossless(QuickFilterListResponse.self, list, "GET /v1/task-filters")
        XCTAssertEqual(decoded.filters.map(\.name), ["Epic", "Needs me"])
        XCTAssertNotNil(decoded.filters.first?.node)

        let missing = try await h.request("DELETE", "/v1/task-filters/ghost", token: token)
        XCTAssertEqual(missing.status, 404)
        let removed = try await h.request("DELETE", "/v1/task-filters/epic", token: token)
        XCTAssertEqual(removed.status, 200)
        XCTAssertEqual(h.api.tasks.quickFilters.map(\.id), ["needs-me"])
    }

    func testSuggestionRoutesDecodeIntoKitTypesAndKeepTheirJSON() async throws {
        h.api.tasks.suggest(SuggestTaskRequest(draft: .init(key: "k", title: "Review PR", due: nil), kind: .pr, sourceRef: "pr:1"))
        h.api.tasks.suggest(SuggestTaskRequest(draft: .init(key: "k2", title: "Send notes", due: "Friday"), kind: .pr, sourceRef: "{\"pr\":2}"))
        let list = try await get("/v1/suggestions")
        let suggestions = try lossless(SuggestionListResponse.self, list, "GET /v1/suggestions").suggestions
        XCTAssertEqual(suggestions.count, 2)
        let second = try XCTUnwrap(h.api.tasks.suggestions.first { $0.title == "Send notes" })
        let wire = try XCTUnwrap((list.json["suggestions"] as? [[String: Any]])?.first { $0["id"] as? String == second.id })
        XCTAssertEqual(wire["due"] as? String, "Friday")
        XCTAssertEqual(wire["source_ref"] as? NSDictionary, ["pr": 2] as NSDictionary)
        XCTAssertEqual(wire["created"] as? String, iso.string(from: second.created))

        let accepted = try await post("/v1/suggestions/\(second.id)/accept", ["title": "Send the notes"])
        try lossless(RemoteTask.self, accepted, "POST /v1/suggestions/<id>/accept")
        XCTAssertEqual(accepted.json["title"] as? String, "Send the notes")
        XCTAssertEqual(accepted.json["source_ref"] as? NSDictionary, ["pr": 2] as NSDictionary, "the task keeps the origin the agent gave")
        let first = try XCTUnwrap(h.api.tasks.suggestions.first { $0.title == "Review PR" })
        XCTAssertEqual((list.json["suggestions"] as? [[String: Any]])?.first { $0["id"] as? String == first.id }?["source_ref"] as? String, "pr:1")
        let rejected = try await post("/v1/suggestions/\(first.id)/reject")
        XCTAssertEqual(rejected.json as NSDictionary, ["rejected": first.id] as NSDictionary)
    }

    // MARK: Resources

    func testPetBubbleAndAcknowledgementRoutesDecodeIntoKitTypes() async throws {
        h.api.pet.stateProvider = { PetState(mood: "needsInput", badge: 2) }
        h.api.pet.trickNames = { ["Wave"] }
        h.api.pet.trickHandler = { _ in true }
        let pet = try await get("/v1/pet")
        let decoded = try lossless(RemotePet.self, pet, "GET /v1/pet")
        XCTAssertEqual(pet.json as NSDictionary, ["name": h.api.settings.config.pet.name, "mood": "needsInput", "badge": 2, "tricks": ["Wave"],
                                                  "background": h.api.settings.config.chat.background] as NSDictionary)
        XCTAssertEqual(decoded.badge, 2)
        // With no accent the keys are absent, so the phone keeps the system blue.
        XCTAssertNil(pet.json["accent"])
        h.api.pet.accentProvider = { PetAccent(light: "#FF9500", dark: "#FF9F0A") }
        let accented = try lossless(RemotePet.self, try await get("/v1/pet"), "GET /v1/pet with an accent")
        XCTAssertEqual(accented.accent, "#FF9500")
        XCTAssertEqual(accented.accentDark, "#FF9F0A")
        let trick = try await post("/v1/pet/tricks/Wave")
        XCTAssertEqual(trick.json as NSDictionary, ["performed": "Wave"] as NSDictionary)

        var pressed = 0
        let expires = Date(timeIntervalSince1970: 1_900_000_000)
        h.bubbles.show(BubbleDraft(id: "due", symbol: "calendar", tint: .blue, title: "Task due", subtitle: "today", body: "Send the report",
                                   actions: [.init("done", "Done", style: .primary) { pressed += 1 }], expires: expires))
        let list = try await get("/v1/bubbles")
        let bubbles = try lossless(BubbleListResponse.self, list, "GET /v1/bubbles").bubbles
        let bubble = try XCTUnwrap(bubbles.first)
        XCTAssertEqual(bubble.subtitle, "today")
        XCTAssertEqual(bubble.body, "Send the report")
        XCTAssertEqual(bubble.expires, expires)
        XCTAssertEqual(bubble.actions.map(\.title), ["Done"])
        let press = try await post("/v1/bubbles/due/actions/\(bubble.actions[0].id)")
        XCTAssertEqual(press.json as NSDictionary, ["pressed": bubble.actions[0].id] as NSDictionary)
        XCTAssertEqual(pressed, 1)
    }

    func testAgentAlertTodayAndManifestRoutesDecodeIntoKitTypes() async throws {
        hook("UserPromptSubmit", session: "fin", payload: ["prompt": "Docs"])
        hook("PostToolUse", session: "fin", payload: ["tool_name": "Edit", "tool_input": ["file_path": "/Users/me/web-app/README.md"]])
        hook("Stop", session: "fin", payload: ["last_assistant_message": "Updated the README."])
        let list = try await get("/v1/agents")
        let agents = try lossless(AgentListResponse.self, list, "GET /v1/agents").agents
        XCTAssertEqual(agents.map(\.id), ["claude:fin"])
        XCTAssertNil((list.json["agents"] as? [[String: Any]])?.first?["last_response"], "the list leaves the reply out")
        let detail = try await get("/v1/agents/claude:fin")
        let agent = try lossless(RemoteAgent.self, detail, "GET /v1/agents/<id>")
        XCTAssertEqual(agent.status, .done)
        XCTAssertEqual(agent.lastResponse, "Updated the README.")
        XCTAssertEqual(agent.editedFiles, ["/Users/me/web-app/README.md"])
        let ack = try await post("/v1/agents/claude:fin/acknowledge")
        XCTAssertEqual(ack.json as NSDictionary, ["acknowledged": "claude:fin"] as NSDictionary)

        signals.add(Signal(id: "a", title: "CI failed on main", subtitle: "build 42", url: URL(string: "https://example.com/42"), label: "CI failed",
                           symbol: "xmark.octagon", mood: .failed, ask: "Why?", detail: "log"), notify: false)
        signals.add(Signal(id: "b", title: "Quiet", subtitle: "", url: nil, label: "Note", symbol: "bell", mood: .idle, ask: nil), notify: false)
        let alerts = try await get("/v1/alerts")
        let decodedAlerts = try lossless(AlertListResponse.self, alerts, "GET /v1/alerts").alerts
        let first = try XCTUnwrap(decodedAlerts.first { $0.id == "a" })
        XCTAssertEqual(first.url, "https://example.com/42")
        XCTAssertEqual(first.detail, "log")
        XCTAssertTrue(first.canAsk)
        XCTAssertEqual(decodedAlerts.first { $0.id == "b" }?.canAsk, false)
        let dismissed = try await post("/v1/alerts/a/dismiss")
        XCTAssertEqual(dismissed.json as NSDictionary, ["dismissed": "a"] as NSDictionary)
        let all = try await post("/v1/alerts/dismiss-all")
        XCTAssertEqual(all.json as NSDictionary, ["dismissed": 1] as NSDictionary)
        signals.add(Signal(id: "c", title: "Again", subtitle: "", url: nil, label: "Note", symbol: "bell", mood: .failed, ask: "Why again?"), notify: false)
        let ask = try await post("/v1/alerts/c/ask")
        XCTAssertEqual(ask.status, 200)
        XCTAssertNotNil(ask.json["outcome"] as? String)

        _ = try h.api.tasks.create(CreateTaskRequest(title: "Review", notes: "", status: .needsYou, source: .user, due: nil, links: [],
                                                     waitingOn: nil, sourceRef: nil, labels: [:], by: "test"))
        hook("UserPromptSubmit", session: "ask", payload: ["prompt": "Fix"])
        hook("Notification", session: "ask", payload: ["message": "Needs permission"])
        signals.add(Signal(id: "d", title: "Open", subtitle: "", url: URL(string: "https://example.com/d"), label: "Note", symbol: "bell", mood: .failed, ask: nil), notify: false)
        for kind in Brief.Kind.allCases {
            let today = try await get("/v1/today?kind=\(kind.rawValue)")
            let decodedToday = try lossless(RemoteToday.self, today, "GET /v1/today?kind=\(kind.rawValue)")
            XCTAssertEqual(decodedToday.kind, kind.rawValue)
        }
        let brief = try lossless(RemoteToday.self, try await get("/v1/today?kind=brief"), "GET /v1/today")
        let targets = brief.sections.flatMap(\.items).map(\.target)
        XCTAssertTrue(targets.contains { $0.type == .task })
        XCTAssertTrue(targets.contains { $0.type == .session })
        XCTAssertEqual(targets.first { $0.type == .alert }?.url, "https://example.com/d")

        let manifest = try await get("/v1/assets/manifest")
        try lossless(AssetManifestResponse.self, manifest, "GET /v1/assets/manifest")
    }
}
