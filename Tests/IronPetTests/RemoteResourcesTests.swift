import AppKit
import XCTest
@testable import IronPet

/// The pet, bubble, agent, alert, today and asset routes of the remote API, over a real listener and in-memory stores.
@MainActor
final class RemoteResourcesTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var token = ""
    private var deviceID = ""
    private var sessions: SessionStore!
    private var signals: SignalStore!
    private var chat: ChatSession!
    private var turns: [ACPTurn] = []
    private var root: URL!
    private var seen: [APIEvent] = []
    private var previousThreads: URL!

    override func setUp() async throws {
        TestMemory.isolate()
        previousThreads = ThreadStore.directory
        ThreadStore.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-remote-threads-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-remote-res-\(UUID().uuidString)")
        for name in ["bundled", "pets", "backgrounds"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        sessions = SessionStore()
        signals = SignalStore()
        chat = ChatSession(restore: false)
        chat.workspace = FileManager.default.temporaryDirectory
        turns = []
        chat.turnRunner = { [unowned self] turn, _ in turns.append(turn) }
        h = RemoteServerHarness(sessions: sessions, signals: signals, chat: chat,
                                petAssets: MacPetAssets(library: root.appendingPathComponent("pets"), bundled: root.appendingPathComponent("bundled"),
                                                  backgrounds: root.appendingPathComponent("backgrounds")))
        seen = []
        h.events.subscribe { [unowned self] in seen.append($0) }
        try await h.start()
        let paired = try await h.pairDevice()
        token = paired.token
        deviceID = paired.deviceID
    }

    override func tearDown() async throws {
        await h.stop()
        ThreadStore.directory = previousThreads
        try? FileManager.default.removeItem(at: root)
    }

    private func get(_ path: String) async throws -> RemoteReply { try await h.request("GET", path, token: token) }
    private func post(_ path: String) async throws -> RemoteReply { try await h.request("POST", path, token: token, body: [:]) }

    private func hook(_ name: String, session: String = "s1", payload: [String: Any] = [:], workspace: String = "/Users/me/web-app") {
        var payload = payload
        payload["session_id"] = session
        sessions.apply(HookEvent(source: .claude, name: name, payload: payload, origin: SessionOrigin(workspace: workspace)))
    }

    private func sheet(_ name: String, in folder: String, height: Int = 2704, shade: UInt8 = 0) throws -> URL {
        let url = root.appendingPathComponent(folder).appendingPathComponent(name)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let data = rep.bitmapData { data[0] = shade; data[3] = 255 }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func signal(_ id: String, ask: String? = "Why did CI fail?") -> Signal {
        Signal(id: id, title: "CI failed on main", subtitle: "build 42", url: URL(string: "https://example.com/42"), label: "CI failed", symbol: "xmark.octagon",
               mood: .failed, ask: ask)
    }

    // MARK: S9

    func testEveryNewRouteNeedsAValidToken() async throws {
        let routes: [(String, String)] = [
            ("GET", "/v1/pet"), ("POST", "/v1/pet/tricks/Wave"), ("GET", "/v1/bubbles"), ("POST", "/v1/bubbles/x/actions/y"),
            ("GET", "/v1/agents"), ("GET", "/v1/agents/s1"), ("POST", "/v1/agents/s1/acknowledge"), ("POST", "/v1/agents/s1/ask"),
            ("GET", "/v1/alerts"), ("POST", "/v1/alerts/dismiss-all"), ("POST", "/v1/alerts/a/dismiss"), ("POST", "/v1/alerts/a/ask"),
            ("GET", "/v1/today?kind=brief"), ("GET", "/v1/assets/manifest"), ("GET", "/v1/assets/" + String(repeating: "a", count: 64)),
        ]
        for (method, path) in routes {
            let reply = try await h.request(method, path, body: method == "POST" ? [:] : nil)
            XCTAssertEqual(reply.status, 401, "\(method) \(path) without a token")
            // The limiter locks out an anonymous caller after ten tries; the harness clock moves on.
            h.clock.advance(70)
        }
        h.service.revoke(deviceID)
        for (method, path) in routes {
            let reply = try await h.request(method, path, token: token, body: method == "POST" ? [:] : nil)
            XCTAssertEqual(reply.status, 401, "\(method) \(path) with a revoked token")
            h.clock.advance(70)
        }
    }

    // MARK: Pet

    func testThePetRouteHasMoodBadgeNameAndTricks() async throws {
        _ = try sheet("ghost.png", in: "bundled")
        h.api.pet.stateProvider = { PetState(mood: "needsInput", badge: 2) }
        h.api.pet.trickNames = { ["Wave", "Drink water"] }
        var played: [String] = []
        h.api.pet.trickHandler = { name in played.append(name); return name != "Moonwalk" }
        let reply = try await get("/v1/pet")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.json["mood"] as? String, "needsInput")
        XCTAssertEqual(reply.json["badge"] as? Int, 2)
        XCTAssertEqual(reply.json["name"] as? String, h.api.settings.config.pet.name)
        XCTAssertEqual(reply.json["tricks"] as? [String], ["Wave", "Drink water"])
        XCTAssertEqual(reply.json["sprite"] as? String, "pet.sprite")
        let trick = try await post("/v1/pet/tricks/Drink%20water")
        XCTAssertEqual(trick.status, 200)
        XCTAssertEqual(played, ["Drink water"])
        let unknown = try await post("/v1/pet/tricks/Moonwalk")
        XCTAssertEqual(unknown.status, 404)
    }

    // MARK: Bubbles, S5

    func testABubbleButtonRunsItsClosureOnceAndAnUnknownOrUsedIdIs404() async throws {
        var done = 0, snoozed = 0
        h.bubbles.show(BubbleDraft(id: "due", symbol: "calendar", tint: .blue, title: "Task due", body: "Send the report",
                              actions: [.init("done", "Done", style: .primary) { done += 1 }, .init("snooze", "Snooze") { snoozed += 1 }]))
        let list = try await get("/v1/bubbles")
        let bubble = try XCTUnwrap((list.json["bubbles"] as? [[String: Any]])?.first)
        XCTAssertEqual(bubble["mac_only"] as? Bool, false)
        let actions = try XCTUnwrap(bubble["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.compactMap { $0["title"] as? String }, ["Done", "Snooze"])
        let id = try XCTUnwrap(actions.first?["id"] as? String)
        let wrong = try await post("/v1/bubbles/due/actions/not-an-id")
        XCTAssertEqual(wrong.status, 404)
        XCTAssertEqual(done, 0)
        let pressed = try await post("/v1/bubbles/due/actions/\(id)")
        XCTAssertEqual(pressed.status, 200)
        XCTAssertEqual(done, 1)
        XCTAssertEqual(snoozed, 0)
        let again = try await post("/v1/bubbles/due/actions/\(id)")
        XCTAssertEqual(again.status, 404, "the bubble closed with the first press, so its action ids are gone")
        XCTAssertEqual(done, 1, "the closure ran once")
        XCTAssertTrue(seen.contains { $0.kind == .bubbleShown && $0.id == "due" })
        XCTAssertTrue(seen.contains { $0.kind == .bubbleDismissed && $0.id == "due" })
    }

    func testBubblesWithMacOnlyDecisionsCarryNoButtonsAndRefusePresses() async throws {
        var allowed = 0
        let pairing = Announcer.remotePairingBubble(RemotePairingRequest(id: "p1", deviceName: "Phone", created: Date()), machine: "Mac", allow: { allowed += 1 }, deny: {})
        h.bubbles.show(pairing)
        var approved = 0
        let notice = AutomationNotice(id: "automation-approval:a1", symbol: "hand.raised.fill", tint: .warn, title: "Allow \"Backup\"?",
                                      buttons: [.init(title: "Approve", primary: true) { approved += 1 }, .init(title: "Reject", destructive: true) {}], macOnly: true)
        h.bubbles.show(Announcer.automationBubble(notice, dismiss: {}, open: nil))
        let macActions = h.api.bubbles.list().flatMap { $0.actions.map(\.id) }
        XCTAssertEqual(macActions.count, 4, "the Mac keeps every button")
        let list = try await get("/v1/bubbles")
        let bubbles = try XCTUnwrap(list.json["bubbles"] as? [[String: Any]])
        XCTAssertEqual(bubbles.count, 2)
        for bubble in bubbles {
            XCTAssertEqual(bubble["mac_only"] as? Bool, true)
            XCTAssertEqual((bubble["actions"] as? [Any])?.count, 0, "no Allow, Deny, Approve or Reject on the wire")
        }
        for id in macActions {
            for bubble in ["remote-pairing:p1", "automation-approval:a1"] {
                let reply = try await post("/v1/bubbles/\(bubble)/actions/\(id)")
                XCTAssertEqual(reply.status, 404)
            }
        }
        XCTAssertEqual(allowed + approved, 0, "nothing ran")
    }

    func testTheAnnouncersApprovalAndPairingBubblesAreMacOnly() {
        XCTAssertTrue(Announcer.approvalBubble(id: UUID(), heading: "Ghost wants to: Run npm test", detail: "npm test", decide: { _ in }, openChat: {}, open: nil).macOnly)
        let user = TelegramBridge.Pending(user: .init(id: 1, isBot: false, firstName: "X", lastName: nil, username: "x"), chat: 1)
        XCTAssertTrue(Announcer.telegramPairingBubble(user, allow: {}, deny: {}).macOnly)
        XCTAssertTrue(Announcer.remotePairingBubble(RemotePairingRequest(id: "p", deviceName: "P", created: Date()), machine: "M", allow: {}, deny: {}).macOnly)
        let plain = AutomationNotice(id: "n", symbol: "bell", title: "Reminder", buttons: [.init(title: "Done") {}])
        XCTAssertFalse(Announcer.automationBubble(plain, dismiss: {}, open: nil).macOnly, "an ordinary reminder keeps its buttons on the phone")
    }

    // MARK: Agents, S4

    func testANeedsInputSessionIsListedFirstWithItsSummaryAndAcknowledgeClearsADoneOne() async throws {
        hook("UserPromptSubmit", session: "run", payload: ["prompt": "Refactor"])
        hook("UserPromptSubmit", session: "ask", payload: ["prompt": "Fix login"], workspace: "/Users/me/api")
        hook("Notification", session: "ask", payload: ["message": "Needs permission"], workspace: "/Users/me/api")
        hook("UserPromptSubmit", session: "fin", payload: ["prompt": "Docs"], workspace: "/Users/me/docs")
        hook("PostToolUse", session: "fin", payload: ["tool_name": "Edit", "tool_input": ["file_path": "/Users/me/docs/README.md"]], workspace: "/Users/me/docs")
        hook("Stop", session: "fin", payload: ["last_assistant_message": "Updated the README."], workspace: "/Users/me/docs")
        let list = try await get("/v1/agents")
        let agents = try XCTUnwrap(list.json["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.first?["id"] as? String, "claude:ask")
        XCTAssertEqual(agents.first?["status"] as? String, "needs_input")
        XCTAssertEqual(agents.first?["workspace"] as? String, "api")
        XCTAssertEqual(agents.map { $0["status"] as? String }, ["needs_input", "done", "running"])
        XCTAssertEqual(agents[1]["summary"] as? String, sessions.sessions["claude:fin"]?.summary)
        XCTAssertNil(agents[1]["last_response"], "the list leaves the reply out")
        let detail = try await get("/v1/agents/claude:fin")
        XCTAssertEqual(detail.json["last_response"] as? String, "Updated the README.")
        XCTAssertEqual(detail.json["edited_files"] as? [String], ["/Users/me/docs/README.md"])
        let missing = try await get("/v1/agents/nope")
        XCTAssertEqual(missing.status, 404)
        let ack = try await post("/v1/agents/claude:fin/acknowledge")
        XCTAssertEqual(ack.status, 200)
        XCTAssertEqual(sessions.sessions["claude:fin"]?.status ?? .idle, .idle)
        XCTAssertTrue(seen.contains { $0.kind == .agentsChanged })
        let after = try await get("/v1/agents")
        XCTAssertEqual((after.json["agents"] as? [[String: Any]])?.count, 2)
    }

    // MARK: Alerts and Ask Ghost, S7

    func testDismissingAlertsMatchesTheStoreAndPublishesAlertsChanged() async throws {
        signals.add(signal("a"), notify: false)
        signals.add(signal("b"), notify: false)
        let list = try await get("/v1/alerts")
        let alerts = try XCTUnwrap(list.json["alerts"] as? [[String: Any]])
        XCTAssertEqual(alerts.compactMap { $0["id"] as? String }, ["b", "a"])
        XCTAssertEqual(alerts.first?["url"] as? String, "https://example.com/42")
        XCTAssertEqual(alerts.first?["can_ask"] as? Bool, true)
        seen = []
        let one = try await post("/v1/alerts/a/dismiss")
        XCTAssertEqual(one.status, 200)
        XCTAssertEqual(signals.signals.map(\.id), ["b"])
        XCTAssertTrue(seen.contains { $0.kind == .alertsChanged })
        let missing = try await post("/v1/alerts/a/dismiss")
        XCTAssertEqual(missing.status, 404)
        seen = []
        let all = try await post("/v1/alerts/dismiss-all")
        XCTAssertEqual(all.json["dismissed"] as? Int, 1)
        XCTAssertTrue(signals.signals.isEmpty)
        XCTAssertTrue(seen.contains { $0.kind == .alertsChanged })
    }

    func testAskGhostSendsOneMessageNamingTheAlertOrAgentWithOriginRemote() async throws {
        signals.add(signal("a"), notify: false)
        let reply = try await post("/v1/alerts/a/ask")
        XCTAssertEqual(reply.status, 200)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(turns.map(\.prompt), ["Why did CI fail?"])
        let messages = await h.api.chat.messages()
        XCTAssertEqual(messages.filter { $0.origin == "ios" }.count, 1)
        signals.add(signal("quiet", ask: nil), notify: false)
        let none = try await post("/v1/alerts/quiet/ask")
        XCTAssertEqual(none.status, 400)

        hook("UserPromptSubmit", session: "x", workspace: "/Users/me/web-app")
        hook("Notification", session: "x", payload: ["message": "Needs permission"], workspace: "/Users/me/web-app")
        let agent = try await post("/v1/agents/claude:x/ask")
        XCTAssertEqual(agent.status, 200)
        // The first turn is still running, so the message waits in the Mac's queue as one message.
        let queued = await h.api.chat.queue()
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(queued[0].text.contains("web-app"), queued[0].text)
        XCTAssertTrue(queued[0].text.contains("Claude Code"), queued[0].text)
    }

    // MARK: Today, S8

    func testTodayHasTheSectionsAndTargetsOfTheBrief() async throws {
        _ = try h.api.tasks.create(CreateTaskRequest(title: "Review the contract", notes: "", status: .needsYou, source: .user, due: nil, links: [],
                                                     waitingOn: nil, sourceRef: nil, labels: [:], by: "test"))
        hook("UserPromptSubmit", session: "ask", payload: ["prompt": "Fix login"])
        hook("Notification", session: "ask", payload: ["message": "Needs permission"])
        signals.add(signal("a"), notify: false)
        for kind in Brief.Kind.allCases {
            let expected = h.api.today.brief(BriefRequest(kind: kind))
            let reply = try await get("/v1/today?kind=\(kind.rawValue)")
            XCTAssertEqual(reply.status, 200)
            XCTAssertEqual(reply.json["kind"] as? String, kind.rawValue)
            let sections = try XCTUnwrap(reply.json["sections"] as? [[String: Any]])
            XCTAssertEqual(sections.compactMap { $0["id"] as? String }, expected.sections.map(\.id))
            XCTAssertEqual(sections.compactMap { $0["title"] as? String }, expected.sections.map(\.title))
            let items = sections.flatMap { $0["items"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(items.compactMap { $0["id"] as? String }, expected.sections.flatMap(\.items).map(\.id))
            XCTAssertEqual(items.compactMap { $0["title"] as? String }, expected.sections.flatMap(\.items).map(\.title))
            XCTAssertEqual(reply.json["lines"] as? [String], expected.lines)
            for item in items { XCTAssertNotNil((item["target"] as? [String: Any])?["type"] as? String) }
        }
        let brief = try await get("/v1/today?kind=brief")
        let types = ((brief.json["sections"] as? [[String: Any]]) ?? []).flatMap { $0["items"] as? [[String: Any]] ?? [] }.compactMap { ($0["target"] as? [String: Any])?["type"] as? String }
        XCTAssertTrue(types.contains("task"), "\(types)")
        XCTAssertTrue(types.contains("session"), "\(types)")
        XCTAssertTrue(types.contains("alert"), "\(types)")
        let bad = try await get("/v1/today?kind=week")
        XCTAssertEqual(bad.status, 400)
        let defaulted = try await get("/v1/today")
        XCTAssertEqual(defaulted.json["kind"] as? String, "brief")
    }

    func testTargetsKeepTheirTypes() {
        XCTAssertEqual(RemoteResources.target(.task("t"))["type"] as? String, "task")
        XCTAssertEqual(RemoteResources.target(.session(id: "s", workspace: nil, bundleID: nil))["type"] as? String, "session")
        XCTAssertEqual(RemoteResources.target(.alert(id: "a", url: URL(string: "https://x.test")))["url"] as? String, "https://x.test")
        XCTAssertEqual(RemoteResources.target(.meeting("m"))["type"] as? String, "meeting")
    }

    // MARK: Assets, S2 and S3

    func testTheManifestLeavesOutASheetOfTheWrongSizeAndHasHashesAndSizes() async throws {
        _ = try sheet("ghost.png", in: "bundled", shade: 10)
        let fox = try sheet("fox.png", in: "pets", shade: 20)
        _ = try sheet("wrong.png", in: "pets", height: 2000)
        _ = try sheet("codex.png", in: "pets", height: 2288)
        let reply = try await get("/v1/assets/manifest")
        let assets = try XCTUnwrap(reply.json["assets"] as? [[String: Any]])
        let ids = assets.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["pet.sprite", "sprite:codex.png", "sprite:fox.png", "sprite:ghost.png"], "wrong.png is skipped, as the gallery skips it")
        let codex = try XCTUnwrap(assets.first { $0["id"] as? String == "sprite:codex.png" })
        XCTAssertEqual(codex["height"] as? Int, 2288)
        XCTAssertEqual(codex["width"] as? Int, 1536)
        XCTAssertEqual(codex["content_type"] as? String, "image/png")
        XCTAssertEqual((codex["sha256"] as? String)?.count, 64)
        XCTAssertEqual(assets.first?["sha256"] as? String, assets.last?["sha256"] as? String, "pet.sprite is the bundled Ghost while pet.sprite is unset")
        XCTAssertEqual(reply.headers["cache-control"], "no-store", "the manifest is not cached")
        XCTAssertFalse(String(decoding: reply.data, as: UTF8.self).contains(root.path), "no path on the wire")
        try h.api.pet.select(PetEntry(id: fox.path, name: "Fox", url: fox, atlas: try XCTUnwrap(Atlas.load(fox))))
        // The harness runs the server by hand with remote.enabled off, so the settings change that selecting a pet makes stops it.
        await h.controller.settled()
        try await h.start()
        let after = try await get("/v1/assets/manifest")
        let sprite = try XCTUnwrap((after.json["assets"] as? [[String: Any]])?.first { $0["id"] as? String == "pet.sprite" })
        XCTAssertEqual(sprite["sha256"] as? String, (assets.first { $0["id"] as? String == "sprite:fox.png" })?["sha256"] as? String)
    }

    func testAnAssetServesByHashWithImmutableCachingAndAnETag() async throws {
        let file = try sheet("ghost.png", in: "bundled")
        let manifest = try await get("/v1/assets/manifest")
        let hash = try XCTUnwrap(((manifest.json["assets"] as? [[String: Any]])?.first)?["sha256"] as? String)
        let reply = try await get("/v1/assets/\(hash)")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.data, try Data(contentsOf: file))
        XCTAssertEqual(reply.headers["etag"], "\"\(hash)\"")
        XCTAssertEqual(reply.headers["cache-control"], "private, max-age=31536000, immutable")
        XCTAssertEqual(reply.headers["content-type"], "image/png")
        let cached = try await h.request("GET", "/v1/assets/\(hash)", token: token, headers: ["If-None-Match": "\"\(hash)\""])
        XCTAssertEqual(cached.status, 304)
        let unknown = try await get("/v1/assets/" + String(repeating: "0", count: 64))
        XCTAssertEqual(unknown.status, 404)
        let traversal = try await get("/v1/assets/..%2F..%2Fetc%2Fpasswd")
        XCTAssertEqual(traversal.status, 404)
        let tasks = try await get("/v1/tasks")
        XCTAssertEqual(tasks.headers["cache-control"], "no-store", "only assets are cacheable")
    }

    func testChangingThePetPublishesAssetsChangedOnTheSocketBus() async throws {
        _ = try sheet("ghost.png", in: "bundled")
        let fox = try sheet("fox.png", in: "pets", shade: 20)
        seen = []
        try h.api.pet.select(PetEntry(id: fox.path, name: "Fox", url: fox, atlas: try XCTUnwrap(Atlas.load(fox))))
        XCTAssertEqual(seen.filter { $0.kind == .assetsChanged }.count, 1)
        seen = []
        try h.api.pet.select(PetEntry(id: fox.path, name: "Fox", url: fox, atlas: try XCTUnwrap(Atlas.load(fox))))
        XCTAssertEqual(seen.filter { $0.kind == .assetsChanged }.count, 0, "the same pet again changes nothing")
    }
}
