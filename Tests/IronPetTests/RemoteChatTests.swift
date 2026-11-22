import CoreGraphics
import ImageIO
import XCTest
@testable import IronPet
@testable import IronPetCore

/// The chat routes of the remote API over a real listener, with a scripted agent in place of the turn runner.
@MainActor
final class RemoteChatTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var chat: ChatSession!
    private var token = ""
    private var deviceID = ""
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []
    private var uploads: URL!
    private var previousThreads: URL!
    private var threads: URL!

    override func setUp() async throws {
        TestMemory.isolate()
        previousThreads = ThreadStore.directory
        threads = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-remote-chat-threads-\(UUID().uuidString)")
        ThreadStore.directory = threads
        uploads = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-remote-files-\(UUID().uuidString)")
        chat = ChatSession(restore: false, speech: SpeechPlayer())
        chat.workspace = FileManager.default.temporaryDirectory
        turns = []
        deliver = []
        chat.turnRunner = { [unowned self] turn, onEvent in turns.append(turn); deliver.append(onEvent) }
        h = RemoteServerHarness(chat: chat, uploads: uploads)
        try await h.start()
        let paired = try await h.pairDevice()
        token = paired.token
        deviceID = paired.deviceID
    }

    override func tearDown() async throws {
        await h.stop()
        ThreadStore.directory = previousThreads
        try? FileManager.default.removeItem(at: threads)
        try? FileManager.default.removeItem(at: uploads)
    }

    private func settle() async { for _ in 0..<10 { await Task.yield() } }
    private func get(_ path: String) async throws -> RemoteReply { try await h.request("GET", path, token: token) }
    private func post(_ path: String, _ body: [String: Any] = [:]) async throws -> RemoteReply { try await h.request("POST", path, token: token, body: body) }
    private func items(_ reply: RemoteReply) -> [[String: Any]] { reply.json["items"] as? [[String: Any]] ?? [] }

    private func socket(since: Int? = nil) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(h.port)/v1/events" + (since.map { "?since=\($0)" } ?? ""))!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = h.session.webSocketTask(with: request)
        task.resume()
        return task
    }

    typealias Frame = (kind: String, id: String?, seq: Int, at: ContinuousClock.Instant)

    /// Starts reading frames. Cancel the socket, then await the task, to get them.
    private func reading(_ socket: URLSessionWebSocketTask) -> Task<[Frame], Never> {
        Task {
            var result: [Frame] = []
            while let message = try? await socket.receive() {
                guard case .string(let text) = message, let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                result.append((object["kind"] as? String ?? "", object["id"] as? String, object["seq"] as? Int ?? 0, ContinuousClock.now))
            }
            return result
        }
    }

    /// Reads frames for `duration`, then closes the socket.
    private func frames(_ socket: URLSessionWebSocketTask, for duration: Duration = .milliseconds(500)) async -> [Frame] {
        let reader = reading(socket)
        try? await Task.sleep(for: duration)
        socket.cancel(with: .goingAway, reason: nil)
        return await reader.value
    }

    // S1
    func testAPhoneMessageRunsATurnAndShowsInTheChatWithTheIPhoneOrigin() async throws {
        let sent = try await post("/v1/chat/current/messages", ["text": "hello"])
        XCTAssertEqual(sent.status, 200)
        XCTAssertEqual(sent.json["outcome"] as? String, "sent")
        await settle()
        XCTAssertEqual(turns.map(\.prompt), ["hello"])
        let current = try await get("/v1/chat/current")
        let user = try XCTUnwrap(items(current).first)
        XCTAssertEqual(user["kind"] as? String, "user")
        XCTAssertEqual(user["text"] as? String, "hello")
        XCTAssertEqual(user["origin"] as? String, "ios")
        XCTAssertEqual(current.json["running"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(current.json["agent"] as? [String: Any])["id"] as? String, chat.agent.id)
        let empty = try await post("/v1/chat/current/messages", ["text": "  "])
        XCTAssertEqual(empty.status, 400)
        let one = try await get("/v1/chat/messages/\(user["id"] as! String)")
        XCTAssertEqual(one.json["text"] as? String, "hello")
        let missing = try await get("/v1/chat/messages/\(UUID().uuidString)")
        XCTAssertEqual(missing.status, 404)
        let junk = try await get("/v1/chat/messages/nope")
        XCTAssertEqual(junk.status, 404)
    }

    // S2
    func testStreamedTextReachesASocketAtMostTenTimesASecondAndEndsWithTheLastChunk() async throws {
        _ = try await post("/v1/chat/current/messages", ["text": "stream"])
        await settle()
        let socket = socket()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        _ = try await socket.receive()   // hello
        let reader = reading(socket)
        // The newest chat.item the Mac published for any message, to compare with the last frame the socket got.
        var newestItemSeq = 0
        let watch = h.events.subscribe { if $0.kind == .chatItem, $0.id != nil { newestItemSeq = $0.seq } }
        defer { watch.cancel() }
        var text = ""
        let started = ContinuousClock.now
        for index in 1...50 {
            text += "w\(index) "
            deliver[0](.assistant("w\(index) "))
            try await Task.sleep(for: .milliseconds(20))
        }
        let ended = ContinuousClock.now
        let streamed = ended - started
        try await Task.sleep(for: .milliseconds(400))
        socket.cancel(with: .goingAway, reason: nil)
        let received = await reader.value
        let now = try await get("/v1/chat/current")
        let assistantID = try XCTUnwrap(items(now).first { $0["kind"] as? String == "assistant" }?["id"] as? String)
        let ours = received.filter { $0.kind == "chat.item" && $0.id == assistantID }
        let seconds = Double(streamed.components.seconds) + Double(streamed.components.attoseconds) / 1e18
        XCTAssertGreaterThan(ours.count, 3)
        XCTAssertLessThanOrEqual(Double(ours.count), seconds * 10 + 2, "streamed for \(seconds) s")
        for (a, b) in zip(ours, ours.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.at - a.at, .milliseconds(80), "frames are at least about 100 ms apart")
        }
        XCTAssertEqual(try XCTUnwrap(received.last { $0.kind == "chat.item" }).seq, newestItemSeq, "the last event the Mac published reached the socket")
        let full = try await get("/v1/chat/messages/\(assistantID)")
        XCTAssertEqual(full.json["text"] as? String, text)
    }

    func testTheThrottleKeepsTheLastEventAfterABurst() async throws {
        var sent: [APIEvent] = []
        let throttle = RemoteEventThrottle(interval: .milliseconds(50)) { sent.append($0) }
        let at = Date()
        for seq in 1...20 { throttle.push(APIEvent(seq: seq, at: at, kind: .chatItem, id: "a")) }
        throttle.push(APIEvent(seq: 21, at: at, kind: .chatItem, id: "b"))
        throttle.push(APIEvent(seq: 22, at: at, kind: .tasksChanged, id: nil))
        XCTAssertEqual(sent.map(\.seq), [1, 21, 22], "the first event of each message and other kinds pass at once")
        let deadline = Date().addingTimeInterval(10)
        while sent.count < 4, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(sent.map(\.seq), [1, 21, 22, 20])
    }

    // S3
    func testAMessageDuringATurnIsQueuedAndTheSocketHearsIt() async throws {
        _ = try await post("/v1/chat/current/messages", ["text": "first"])
        await settle()
        let socket = socket()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        _ = try await socket.receive()
        let queued = try await post("/v1/chat/current/messages", ["text": "second"])
        XCTAssertEqual(queued.json["outcome"] as? String, "queued")
        let seen = await frames(socket)
        XCTAssertTrue(seen.contains { $0.kind == "chat.state" && $0.id == "queue" })
        let current = try await get("/v1/chat/current")
        let queue = try XCTUnwrap(current.json["queue"] as? [[String: Any]])
        XCTAssertEqual(queue.map { $0["text"] as? String }, ["second"])
        XCTAssertEqual(queue.first?["from_mac"] as? Bool, false)
    }

    // S4
    func testAnApprovalIsAnsweredOnceFromThePhone() async throws {
        _ = try await post("/v1/chat/current/messages", ["text": "delete the build folder"])
        await settle()
        var decision: ApprovalDecision?
        chat.handlePermission(ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "rm -rf build"])) { decision = $0 }
        let current = try await get("/v1/chat/current")
        let approval = try XCTUnwrap((current.json["approvals"] as? [[String: Any]])?.first)
        let id = approval["id"] as! String
        let socket = socket()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        _ = try await socket.receive()
        let bad = try await post("/v1/chat/approvals/\(id)", [:])
        XCTAssertEqual(bad.status, 400)
        let allowed = try await post("/v1/chat/approvals/\(id)", ["allow": true])
        XCTAssertEqual(allowed.status, 200)
        XCTAssertEqual(decision?.allow, true)
        XCTAssertTrue(chat.approvals.isEmpty, "the Mac card is gone")
        let seen = await frames(socket)
        XCTAssertTrue(seen.contains { $0.kind == "chat.state" && $0.id == "approvals" })
        let again = try await post("/v1/chat/approvals/\(id)", ["allow": true])
        XCTAssertEqual(again.status, 404)
        let unknown = try await post("/v1/chat/approvals/not-an-id", ["allow": false])
        XCTAssertEqual(unknown.status, 404)
    }

    // S5
    func testAFormIsAnsweredAndSubmittedOrSkippedFromThePhone() async throws {
        _ = try await post("/v1/chat/current/messages", ["text": "ask me"])
        await settle()
        let form = ElicitationForm(message: "Which one?", fields: [
            ElicitationField(id: "pick", title: "Pick", detail: "", required: true, kind: .single([ElicitationOption(value: "a", title: "A", detail: ""), ElicitationOption(value: "b", title: "B", detail: "")])),
            ElicitationField(id: "tags", title: "Tags", detail: "", required: false, kind: .multi([ElicitationOption(value: "x", title: "X", detail: "")])),
            ElicitationField(id: "sure", title: "Sure", detail: "", required: false, kind: .boolean)])
        var reply: ElicitationReply?
        chat.handleElicitation(form) { reply = $0 }
        var current = try await get("/v1/chat/current")
        let shown = try XCTUnwrap((current.json["forms"] as? [[String: Any]])?.first)
        let id = shown["id"] as! String
        XCTAssertEqual((shown["fields"] as? [[String: Any]])?.map { $0["type"] as? String }, ["single", "multi", "boolean"])
        XCTAssertEqual(shown["can_submit"] as? Bool, false)
        let early = try await post("/v1/chat/forms/\(id)/submit")
        XCTAssertEqual(early.status, 400)
        let wrong = try await post("/v1/chat/forms/\(id)", ["answers": ["pick": 3]])
        XCTAssertEqual(wrong.status, 400)
        let answered = try await post("/v1/chat/forms/\(id)", ["answers": ["pick": "a"]])
        XCTAssertEqual(answered.status, 200)
        current = try await get("/v1/chat/current")
        XCTAssertEqual(((current.json["forms"] as? [[String: Any]])?.first?["answers"] as? [String: Any])?["pick"] as? String, "a")
        let submitted = try await post("/v1/chat/forms/\(id)/submit", ["answers": ["tags": ["x"], "sure": true]])
        XCTAssertEqual(submitted.status, 200)
        XCTAssertEqual(reply, .accept(["pick": "a", "tags": ["x"], "sure": true]))
        let gone = try await post("/v1/chat/forms/\(id)/skip")
        XCTAssertEqual(gone.status, 404)

        var second: ElicitationReply?
        chat.handleElicitation(form) { second = $0 }
        current = try await get("/v1/chat/current")
        let other = (current.json["forms"] as? [[String: Any]])?.first?["id"] as! String
        let skipped = try await post("/v1/chat/forms/\(other)/skip")
        XCTAssertEqual(skipped.status, 200)
        XCTAssertNotNil(second)
        XCTAssertTrue(chat.forms.isEmpty)
    }

    // S6
    func testOpenAndNewAreRefusedWhileBusyAndWorkWhenIdle() async throws {
        let saved = ChatThread(id: "t-1", title: "Old chat", workspace: "/tmp/web-app", updatedAt: Date(), items: [ChatItem(kind: .user("old question")), ChatItem(kind: .assistant("old answer"))], agent: chat.agent.id)
        ThreadStore.save(saved)
        chat.items = [ChatItem(kind: .user("now"))]
        _ = try await post("/v1/chat/current/messages", ["text": "work"])
        await settle()
        let before = chat.items.map(\.id), threadBefore = chat.threadID
        for path in ["/v1/chat/open/t-1", "/v1/chat/new"] {
            let refused = try await post(path)
            XCTAssertEqual(refused.status, 409, path)
            XCTAssertFalse(((refused.json["error"] as? [String: Any])?["message"] as? String ?? "").isEmpty)
            XCTAssertEqual(chat.items.map(\.id), before, "the Mac chat stays as it was")
            XCTAssertEqual(chat.threadID, threadBefore)
            XCTAssertTrue(chat.isRunning)
        }
        deliver[0](.finished(error: nil))
        await settle()
        var decision: ApprovalDecision?
        chat.handlePermission(ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "ls"])) { decision = $0 }
        let waiting = try await post("/v1/chat/open/t-1")
        XCTAssertEqual(waiting.status, 409)
        XCTAssertNil(decision, "the approval was not answered by the refusal")
        chat.decide(id: chat.approvals[0].id, allow: false)
        let missing = try await post("/v1/chat/open/nope")
        XCTAssertEqual(missing.status, 404)
        let opened = try await post("/v1/chat/open/t-1")
        XCTAssertEqual(opened.status, 200)
        XCTAssertEqual(chat.threadID, "t-1")
        XCTAssertEqual(chat.items.count, 2)
        let fresh = try await post("/v1/chat/new")
        XCTAssertEqual(fresh.status, 200)
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertNil(chat.threadID)
    }

    private func patch(_ body: [String: Any]) async throws -> RemoteReply { try await h.request("PATCH", "/v1/chat/options", token: token, body: body) }

    /// Gives the chat a model list, as the agent does when its session starts.
    private func offerModels() async throws {
        _ = try await post("/v1/chat/current/messages", ["text": "hi"])
        await settle()
        deliver[0](.models(current: nil, [ChatModel(id: "m1", name: "Model one"), ChatModel(id: "m2", name: "Model two")]))
        deliver[0](.finished(error: nil))
        await settle()
    }

    func testTheChatSnapshotListsTheSettingsTheMacOffers() async throws {
        try await offerModels()
        let options = try await get("/v1/chat/current").json["options"] as? [String: Any] ?? [:]
        XCTAssertEqual((options["models"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["m1", "m2"])
        XCTAssertEqual((options["agents"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, chat.agents.map(\.id))
        XCTAssertEqual(options["folder"] as? String, chat.workspace?.path)
        XCTAssertNil(options["auto_mode"], "the phone has no auto toggle of its own")
        XCTAssertNil(options["modes"], "an agent that advertises no modes sends none")
    }

    /// The phone shows the list the agent advertises and the one in force, and picking one is the Mac picker's call.
    func testTheChatSnapshotListsTheAgentsModesAndAPhonePicksOneLikeTheMacPicker() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "chatMode.\(chat.agent.id)") }
        chat.receiveModes(current: "default", modes: [AgentMode(id: "default", name: "Default", detail: "Asks first"), AgentMode(id: "acceptEdits", name: "Accept edits"),
                                                       AgentMode(id: "plan", name: "Plan"), AgentMode(id: "bypassPermissions", name: "Bypass permissions")])
        let options = try await get("/v1/chat/current").json["options"] as? [String: Any] ?? [:]
        let modes = options["modes"] as? [[String: Any]] ?? []
        XCTAssertEqual(modes.compactMap { $0["id"] as? String }, ["default", "acceptEdits", "plan", "bypassPermissions"], "the agent's own list, in its order")
        XCTAssertEqual(modes.first?["detail"] as? String, "Asks first")
        XCTAssertNil(modes[1]["detail"], "no detail is an absent key")
        XCTAssertEqual(options["mode"] as? String, "default")

        let picked = try await patch(["mode": "plan"])
        XCTAssertEqual(picked.status, 200)
        XCTAssertEqual(chat.agentMode, "plan", "the same session call as the Mac's picker")
        let after = try await get("/v1/chat/current").json["options"] as? [String: Any] ?? [:]
        XCTAssertEqual(after["mode"] as? String, "plan")

        for body: [String: Any] in [["mode": "auto"], ["mode": true], ["mode": ""], ["auto_mode": true, "mode": "nope"]] {
            let refused = try await patch(body)
            XCTAssertEqual(refused.status, 400, "\(body): a mode the agent does not offer is refused")
        }
        XCTAssertEqual(chat.agentMode, "plan")
    }

    func testAPhoneChangesTheModelAndTheModeAndTheMacChatAndNextTurnUseThem() async throws {
        defer {
            UserDefaults.standard.removeObject(forKey: "chatModel.\(chat.agent.id)"); UserDefaults.standard.removeObject(forKey: "cachedModels.\(chat.agent.id)")
            UserDefaults.standard.removeObject(forKey: "chatMode.\(chat.agent.id)")
        }
        try await offerModels()
        chat.receiveModes(current: "default", modes: [AgentMode(id: "default", name: "Default"), AgentMode(id: "acceptEdits", name: "Accept edits")])
        let changed = try await patch(["model": "m2", "mode": "acceptEdits"])
        XCTAssertEqual(changed.status, 200)
        XCTAssertEqual(chat.model, "m2")
        XCTAssertEqual(chat.agentMode, "acceptEdits")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "chatModel.\(chat.agent.id)"), "m2", "stored the same way as a Mac change")
        let current = try await get("/v1/chat/current").json
        XCTAssertEqual(current["model"] as? String, "m2")
        XCTAssertEqual((current["options"] as? [String: Any])?["mode"] as? String, "acceptEdits")
        _ = try await post("/v1/chat/current/messages", ["text": "next"])
        await settle()
        XCTAssertEqual(turns.last?.model, "m2", "the next turn runs with the phone's model")
        let reset = try await patch(["model": NSNull()])
        XCTAssertEqual(reset.status, 409, "the second turn is still running")
        XCTAssertEqual(chat.model, "m2")
        let back = try await patch(["mode": "default"])
        XCTAssertEqual(back.status, 200, "the mode changes during a turn, as on the Mac")
        XCTAssertEqual(chat.agentMode, "default")
    }

    func testBadSettingsAreRefusedBeforeAnythingChanges() async throws {
        try await offerModels()
        chat.receiveModes(current: "default", modes: [AgentMode(id: "default", name: "Default")])
        let before = (chat.agent.id, chat.model, chat.agentMode, chat.workspace)
        for body: [String: Any] in [["model": "nope"], ["agent": "nope"], ["folder": "/etc"], ["mode": "yes"], ["model": 3],
                                    ["agent": chat.agent.id, "model": "nope", "mode": "default"], ["model": "m2", "mode": "nope"], ["folder": "/etc", "no_project": true]] {
            let reply = try await patch(body)
            XCTAssertEqual(reply.status, 400, "\(body)")
        }
        XCTAssertEqual(chat.agent.id, before.0)
        XCTAssertEqual(chat.model, before.1)
        XCTAssertEqual(chat.agentMode, before.2)
        XCTAssertEqual(chat.workspace, before.3)
    }

    func testNoProjectLeavesTheFolderOut() async throws {
        let before = chat.workspace
        defer { chat.workspace = before }
        _ = try await patch(["no_project": true])
        let options = try await get("/v1/chat/current").json["options"] as? [String: Any] ?? [:]
        XCTAssertNil(options["folder"], "no project is an absent folder, not the scratch path")
    }

    func testSettingsNeedAPairedDevice() async throws {
        chat.receiveModes(current: "default", modes: [AgentMode(id: "default", name: "Default"), AgentMode(id: "plan", name: "Plan")])
        let reply = try await h.request("PATCH", "/v1/chat/options", token: nil, body: ["mode": "plan"])
        XCTAssertEqual(reply.status, 401)
        XCTAssertEqual(chat.agentMode, "default")
    }

    // S7
    func testThreadsListMatchesTheAPIAndOneThreadCanBeRead() async throws {
        ThreadStore.save(ChatThread(id: "t-1", title: "First", workspace: "/tmp/web-app", updatedAt: Date(), items: [ChatItem(kind: .user("q")), ChatItem(kind: .assistant("a"))], agent: chat.agent.id))
        ThreadStore.save(ChatThread(id: "t-2", title: "Second", workspace: "/tmp/api", updatedAt: Date().addingTimeInterval(-60), items: [], agent: chat.agent.id))
        chat.refreshHistory()
        let listed = try await get("/v1/chat/threads")
        let ids = (listed.json["threads"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let expected = await h.api.chat.threads().map(\.id)
        XCTAssertEqual(ids, expected)
        XCTAssertEqual(Set(ids), ["t-1", "t-2"])
        let one = try await get("/v1/chat/threads/t-1")
        XCTAssertEqual(one.json["title"] as? String, "First")
        XCTAssertEqual(one.json["folder_label"] as? String, "web-app", "the folder name only, never its path")
        XCTAssertEqual(items(one).map { $0["text"] as? String }, ["q", "a"])
        let unknown = try await get("/v1/chat/threads/nope")
        XCTAssertEqual(unknown.status, 404)
    }

    // S8
    private func upload(_ data: Data, name: String, token: String? = nil, type: String = "image/jpeg") async throws -> RemoteReply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/v1/uploads")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token ?? self.token)", forHTTPHeaderField: "Authorization")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name, forHTTPHeaderField: "X-File-Name")
        request.httpBody = data
        let (body, response) = try await h.session.data(for: request)
        return RemoteReply(status: (response as! HTTPURLResponse).statusCode, data: body, headers: [:])
    }

    /// S7: a JPEG the phone pasted reaches the agent as an ACP image block, like a Mac paste, not as a path in the prompt text.
    func testAPastedJPEGFromThePhoneIsAnImageBlockForTheAgent() async throws {
        let bytes = try XCTUnwrap(Self.jpeg())
        let up = try await upload(bytes, name: "pasted-image-1.jpg")
        XCTAssertEqual(up.status, 201)
        let id = try XCTUnwrap(up.json["id"] as? String)
        let sent = try await post("/v1/chat/current/messages", ["text": "what is this", "upload_ids": [id]])
        XCTAssertEqual(sent.json["outcome"] as? String, "sent")
        await settle()
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.images.count, 1, "the upload is an image of the turn")
        XCTAssertTrue(turn.files.isEmpty, "it is not listed as a plain file")
        let image = try XCTUnwrap(turn.images.first)
        XCTAssertEqual(image.pathExtension, "jpg")
        XCTAssertTrue(image.path.hasPrefix(uploads.path), "the file is under the temporary upload folder, never ~/.ironpet")
        let block = try XCTUnwrap(ACPBackend.imageBlock(image))
        XCTAssertEqual(block["type"] as? String, "image")
        XCTAssertEqual(block["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(block["data"] as? String, bytes.base64EncodedString())
    }

    private static func jpeg() -> Data? {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let image = context?.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    func testUploadsAreCappedStoredByNameOnlyAndBoundToTheirDevice() async throws {
        let huge = try await upload(Data(count: 25 << 20), name: "big.bin")
        XCTAssertEqual(huge.status, 413)
        let photo = try await upload(Data(repeating: 7, count: 2_000_000), name: "../../evil.jpg")
        XCTAssertEqual(photo.status, 201)
        let id = photo.json["id"] as! String
        XCTAssertEqual(photo.json["file_name"] as? String, "evil.jpg")
        XCTAssertTrue((photo.json["stored_name"] as? String ?? "").hasSuffix("-evil.jpg"))
        let folder = uploads.appendingPathComponent(deviceID)
        let stored = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored[0].hasSuffix("-evil.jpg"), stored[0])
        XCTAssertGreaterThan(stored[0].count, "-evil.jpg".count)

        let other = try await h.pairDevice(name: "Other phone")
        let stolen = try await h.request("POST", "/v1/chat/current/messages", token: other.token, body: ["text": "mine", "upload_ids": [id]])
        XCTAssertEqual(stolen.status, 404, "another device cannot use the id")
        let sent = try await post("/v1/chat/current/messages", ["text": "see photo", "upload_ids": [id]])
        XCTAssertEqual(sent.json["outcome"] as? String, "sent")
        await settle()
        XCTAssertEqual(turns.first?.images.map(\.lastPathComponent), stored)
        let afterSend = try await get("/v1/chat/current")
        let shown = items(afterSend)
        let shot = try XCTUnwrap(shown.first { $0["kind"] as? String == "screenshot" })
        XCTAssertEqual(shot["file_name"] as? String, stored[0])
        XCTAssertNil(shot["path"], "the Mac path never leaves the Mac")
        let reuse = try await post("/v1/chat/current/messages", ["text": "again", "upload_ids": [id]])
        XCTAssertEqual(reuse.status, 404, "an id works once")

        let json = "{\"text\":\"\(String(repeating: "a", count: 2 << 20))\"}"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/v1/chat/current/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(json.utf8)
        let (_, response) = try await h.session.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 413, "other routes keep 1 MiB")
        let empty = try await upload(Data(), name: "x")
        XCTAssertEqual(empty.status, 400)
    }

    /// Sends one upload and returns the id of the attachment message it made.
    private func sentAttachment(_ data: Data, name: String) async throws -> (id: String, stored: String) {
        let saved = try await upload(data, name: name)
        let sent = try await post("/v1/chat/current/messages", ["text": "look", "upload_ids": [saved.json["id"] as! String]])
        XCTAssertEqual(sent.json["outcome"] as? String, "sent")
        await settle()
        let current = try await get("/v1/chat/current")
        let shot = try XCTUnwrap(items(current).first { $0["kind"] as? String == "screenshot" })
        return (shot["id"] as! String, shot["file_name"] as! String)
    }

    /// Step 4 of #190: the phone fetches the image behind an attachment message, with the device's token and nothing else.
    func testAnAttachmentImageStreamsToAPairedDeviceAndToNoOneElse() async throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let shot = try await sentAttachment(bytes, name: "screen.png")
        let path = "/v1/chat/messages/\(shot.id)/file"

        let fetched = try await get(path)
        XCTAssertEqual(fetched.status, 200)
        XCTAssertEqual(fetched.data, bytes)
        XCTAssertEqual(fetched.headers["content-type"], "image/png")
        XCTAssertEqual(fetched.headers["cache-control"], "no-store")

        let anonymous = try await h.request("GET", path)
        XCTAssertEqual(anonymous.status, 401, "an unpaired request is refused")
        XCTAssertNotEqual(anonymous.data, bytes)
        let forged = try await h.request("GET", path, token: "not-a-token")
        XCTAssertEqual(forged.status, 401)

        let other = try await h.pairDevice(name: "Other phone")
        let second = try await h.request("GET", path, token: other.token)
        XCTAssertEqual(second.status, 200, "every paired device reads the one shared chat")
    }

    func testTheFileRouteSendsOnlyImagesOfTheOpenChatAndNeverReadsAPathTheClientNames() async throws {
        let text = try await sentAttachment(Data("hello".utf8), name: "notes.txt")
        let notImage = try await get("/v1/chat/messages/\(text.id)/file")
        XCTAssertEqual(notImage.status, 404)
        XCTAssertEqual((notImage.json["error"] as? [String: Any])?["code"] as? String, "not_found")

        let current = try await get("/v1/chat/current")
        let user = try XCTUnwrap(items(current).first { $0["kind"] as? String == "user" })
        let message = try await get("/v1/chat/messages/\(user["id"] as! String)/file")
        XCTAssertEqual(message.status, 404, "a text message has no file")
        let unknown = try await get("/v1/chat/messages/\(UUID().uuidString)/file")
        XCTAssertEqual(unknown.status, 404)
        let traversal = try await get("/v1/chat/messages/..%2F..%2Fetc%2Fpasswd/file")
        XCTAssertEqual(traversal.status, 404)
        let byPath = try await get("/v1/chat/messages/\(text.stored)/file")
        XCTAssertEqual(byPath.status, 404, "a stored file name is not a message id")
    }

    // MARK: File previews

    /// A project folder the chat works in, with an `outside` folder beside it that the chat does not know.
    private func previewFolders() throws -> (project: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-\(UUID().uuidString)")
        let project = base.appendingPathComponent("project"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        // The temporary folder is a symbolic link on macOS, so the chat folder is the resolved path, as a folder picker gives it.
        chat.workspace = project.resolvingSymlinksInPath()
        return (project.resolvingSymlinksInPath(), outside.resolvingSymlinksInPath())
    }

    private func preview(_ path: String, token override: String? = nil) async throws -> RemoteReply {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return try await h.request("GET", "/v1/files/preview?path=\(encoded)", token: override ?? token)
    }

    private func message(_ reply: RemoteReply) -> String { (reply.json["error"] as? [String: Any])?["message"] as? String ?? "" }
    private func code(_ reply: RemoteReply) -> String { (reply.json["error"] as? [String: Any])?["code"] as? String ?? "" }

    func testAPathInsideTheChatFolderShowsItsTextAndOneOutsideIsRefusedWithAReason() async throws {
        let (project, outside) = try previewFolders()
        let file = project.appendingPathComponent("src/my file.swift")
        try "let answer = 42\n".write(to: file, atomically: true, encoding: .utf8)
        let secret = outside.appendingPathComponent("notes.txt")
        try "not for the phone".write(to: secret, atomically: true, encoding: .utf8)

        let ok = try await preview(file.path)
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(String(data: ok.data, encoding: .utf8), "let answer = 42\n")
        XCTAssertTrue(ok.headers["content-type"]?.hasPrefix("text/plain") == true, "\(ok.headers)")
        XCTAssertEqual(ok.headers["cache-control"], "no-store")
        XCTAssertNil(ok.headers["x-ironpet-truncated"])

        let refused = try await preview(secret.path)
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(code(refused), "forbidden")
        XCTAssertTrue(message(refused).contains("folders its chat works in"), message(refused))
        XCTAssertFalse(String(data: refused.data, encoding: .utf8)?.contains("not for the phone") == true)
        // Whether the file exists is not revealed outside the chat's folders.
        let missingOutside = try await preview(outside.appendingPathComponent("nope.txt").path)
        XCTAssertEqual(missingOutside.status, 403)
        XCTAssertEqual(message(missingOutside), message(refused))
        // The recent folders are not roots, so a folder the user once picked does not open up either.
        XCTAssertTrue(chat.recents.contains { secret.path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }, "the test needs a recent folder that holds the outside file: \(chat.recents)")
    }

    func testWithNoFolderOpenNothingIsPreviewed() async throws {
        let (project, _) = try previewFolders()
        let file = project.appendingPathComponent("a.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        chat.workspace = nil
        let reply = try await preview(file.path)
        XCTAssertEqual(reply.status, 403)
    }

    func testPreviewFollowsNoWayOutOfTheFolder() async throws {
        let (project, outside) = try previewFolders()
        let target = outside.appendingPathComponent("target.txt")
        try "outside".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link.txt"), withDestinationURL: target)
        let viaLink = try await preview(project.appendingPathComponent("link.txt").path)
        XCTAssertEqual(viaLink.status, 403, "a link inside the folder does not reach outside it")
        let traversal = try await preview(project.path + "/src/../../outside/target.txt")
        XCTAssertEqual(traversal.status, 403)
        let sibling = try await preview(project.path + "-other/file.txt")
        XCTAssertEqual(sibling.status, 403, "a folder that only shares the name prefix is not inside")
        let root = try await preview("/etc/hosts")
        XCTAssertEqual(root.status, 403)
    }

    func testPreviewRefusesKeysAndEnvFilesEvenInsideTheFolder() async throws {
        let (project, _) = try previewFolders()
        for name in [".env", ".env.local", ".ENV", "server.PEM", "deploy.key", "id_rsa", "ID_RSA", ".netrc"] {
            try "SECRET=1".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let reply = try await preview(project.appendingPathComponent(name).path)
            XCTAssertEqual(reply.status, 403, name)
            XCTAssertTrue(message(reply).contains("keys or .env"), name)
        }
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "x".write(to: project.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let ssh = try await preview(project.appendingPathComponent(".ssh/config").path)
        XCTAssertEqual(ssh.status, 403)
    }

    func testPreviewDoesNotOpenAPipe() async throws {
        let (project, _) = try previewFolders()
        let pipe = project.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let reply = try await preview(pipe.path)
        XCTAssertEqual(reply.status, 415)
    }

    func testPreviewAnswersImagesBinariesFoldersAndMissingFilesWithClearErrors() async throws {
        let (project, _) = try previewFolders()
        let image = project.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).write(to: image)
        let shown = try await preview(image.path)
        XCTAssertEqual(shown.status, 200)
        XCTAssertEqual(shown.headers["content-type"], "image/png")
        XCTAssertEqual(shown.data, Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))

        let binary = project.appendingPathComponent("blob.bin")
        try Data([0x50, 0x4B, 0, 3, 4]).write(to: binary)
        let notText = try await preview(binary.path)
        XCTAssertEqual(notText.status, 415)
        XCTAssertTrue(message(notText).contains("text files and images"))

        let folder = try await preview(project.appendingPathComponent("src").path)
        XCTAssertEqual(folder.status, 400)
        XCTAssertTrue(message(folder).contains("folder"))

        let gone = try await preview(project.appendingPathComponent("src/gone.swift").path)
        XCTAssertEqual(gone.status, 404)
        XCTAssertTrue(message(gone).contains("no such file"))

        let relative = try await preview("src/a.swift")
        XCTAssertEqual(relative.status, 400)
        XCTAssertTrue(message(relative).contains("absolute"))
        let empty = try await preview("")
        XCTAssertEqual(empty.status, 400)
    }

    func testPreviewSendsTheStartOfALongFileAndSaysSo() async throws {
        let (project, _) = try previewFolders()
        let long = project.appendingPathComponent("long.log")
        try Data(repeating: UInt8(ascii: "a"), count: RemoteFilePreview.maxTextBytes + 5000).write(to: long)
        let reply = try await preview(long.path)
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.data.count, RemoteFilePreview.maxTextBytes)
        XCTAssertEqual(reply.headers["x-ironpet-truncated"], "1")
        // A cut in the middle of a multi-byte character is still text.
        let accents = project.appendingPathComponent("accents.txt")
        try Data(repeating: 0, count: 0).write(to: accents)
        try String(repeating: "é", count: RemoteFilePreview.maxTextBytes).write(to: accents, atomically: true, encoding: .utf8)
        let cut = try await preview(accents.path)
        XCTAssertEqual(cut.status, 200)
        XCTAssertNotNil(String(data: cut.data, encoding: .utf8))
    }

    func testPreviewNeedsAPairedDevice() async throws {
        let (project, _) = try previewFolders()
        let file = project.appendingPathComponent("a.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        let anonymous = try await h.request("GET", "/v1/files/preview?path=\(file.path)")
        XCTAssertEqual(anonymous.status, 401)
        let forged = try await preview(file.path, token: "forged")
        XCTAssertEqual(forged.status, 401)
        let rows = h.service.store.accessLog(limit: 20)
        for row in rows { XCTAssertFalse(row.route.contains("a.txt"), "the log holds no file path: \(row.route)") }
    }

    func testAnImageThatIsGoneFromTheMacIsA404NotACrash() async throws {
        let shot = try await sentAttachment(Data(repeating: 9, count: 64), name: "gone.png")
        let folder = uploads.appendingPathComponent(deviceID)
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) { try FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        let reply = try await get("/v1/chat/messages/\(shot.id)/file")
        XCTAssertEqual(reply.status, 404)
        XCTAssertTrue(((reply.json["error"] as? [String: Any])?["message"] as? String ?? "").contains("no longer on the Mac"), "\(reply.json)")
    }

    func testTheAccessLogHoldsNoMessageTextOrFileName() async throws {
        _ = try await upload(Data(repeating: 1, count: 10), name: "secret-name.png")
        _ = try await post("/v1/chat/current/messages", ["text": "my secret text"])
        let rows = h.service.store.accessLog(limit: 50)
        XCTAssertTrue(rows.contains { $0.route == "/v1/uploads" })
        XCTAssertTrue(rows.contains { $0.route == "/v1/chat/current/messages" })
        for row in rows { XCTAssertFalse(row.route.contains("secret"), row.route) }
    }

    // S9
    func testAReplyQuotesTheMessageLikeAMacReply() async throws {
        let answer = ChatItem(kind: .assistant("The build is green."), date: Date(timeIntervalSince1970: 0))
        chat.items = [answer]
        let reply = try await post("/v1/chat/current/messages", ["text": "why?", "reply": ["item_id": answer.id.uuidString]])
        XCTAssertEqual(reply.status, 200)
        await settle()
        let after = try await get("/v1/chat/current")
        let user = try XCTUnwrap(items(after).last)
        XCTAssertEqual((user["reply"] as? [String: Any])?["item_id"] as? String, answer.id.uuidString)
        XCTAssertTrue(try XCTUnwrap(turns.first?.prompt).contains("The build is green."))
        XCTAssertTrue(try XCTUnwrap(turns.first?.prompt).hasSuffix("why?"))
        deliver[0](.finished(error: nil))
        await settle()
        let selection = try await post("/v1/chat/current/messages", ["text": "and?", "reply": ["item_id": answer.id.uuidString, "selection_text": "green"]])
        XCTAssertEqual(selection.status, 200)
        await settle()
        let afterSelection = try await get("/v1/chat/current")
        let quote = try XCTUnwrap(items(afterSelection).last?["reply"] as? [String: Any])
        XCTAssertEqual(quote["text"] as? String, "green")
        XCTAssertEqual(quote["selection"] as? Bool, true)
        let unknown = try await post("/v1/chat/current/messages", ["text": "x", "reply": ["item_id": UUID().uuidString]])
        XCTAssertEqual(unknown.status, 400)
    }

    // S10
    func testStopEndsAPhoneTurnAndLeavesTheMacDraftAlone() async throws {
        _ = try await post("/v1/chat/current/messages", ["text": "long job"])
        await settle()
        XCTAssertTrue(chat.isRunning)
        let stopped = try await post("/v1/chat/current/stop")
        XCTAssertEqual(stopped.status, 200)
        XCTAssertFalse(chat.isRunning)
        let current = try await get("/v1/chat/current")
        XCTAssertTrue(["idle", "failed"].contains(current.json["state"] as? String ?? ""), "\(current.json["state"] ?? "")")
    }

    // S11
    func testAPhoneTurnIsNotReadAloud() async throws {
        var spoken: [String] = []
        chat.speech.isEnabled = { true }
        chat.player.synthesize = { text in spoken.append(text); throw CancellationError() }
        _ = try await post("/v1/chat/current/messages", ["text": "status?"])
        await settle()
        deliver[0](.assistant("All green."))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertEqual(spoken, [])
    }

    // S12
    func testTheTranscriptBadgeForAPhoneMessageReadsIPhone() {
        let badge = ChatOrigin.badge(for: "ios")
        XCTAssertEqual(badge?.label, "iPhone")
        XCTAssertEqual(badge?.help, "Sent from iPhone")
        XCTAssertNil(ChatOrigin.badge(for: "telegram"))
        XCTAssertNil(ChatOrigin.badge(for: nil))
    }

    func testAnUnknownKindStaysAStringOnTheWire() {
        let json = RemoteChat.json(ChatItem(kind: .tool("Ran `ls`", ok: true)))
        XCTAssertEqual(json["kind"] as? String, "tool")
        XCTAssertEqual(json["ok"] as? Bool, true)
    }

    func testASystemNoticeIsANoticeKindWithItsTextAndAnEmptyOneIsHidden() async throws {
        XCTAssertEqual(RemoteChat.json(ChatItem(kind: .notice("Automation ran")))["kind"] as? String, "notice")
        XCTAssertEqual(RemoteChat.json(ChatItem(kind: .notice("Automation ran")))["text"] as? String, "Automation ran")
        chat.items = [ChatItem(kind: .notice("")), ChatItem(kind: .notice("Visible"))]
        let current = try await get("/v1/chat/current")
        XCTAssertEqual(items(current).map { $0["text"] as? String }, ["Visible"])
    }
}
