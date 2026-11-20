import XCTest
@testable import IronPet

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
        chat = ChatSession(restore: false)
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

    typealias Frame = (kind: String, id: String?, at: ContinuousClock.Instant)

    /// Starts reading frames. Cancel the socket, then await the task, to get them.
    private func reading(_ socket: URLSessionWebSocketTask) -> Task<[Frame], Never> {
        Task {
            var result: [Frame] = []
            while let message = try? await socket.receive() {
                guard case .string(let text) = message, let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                result.append((object["kind"] as? String ?? "", object["id"] as? String, ContinuousClock.now))
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
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ours.last).at, ended - .milliseconds(120), "the last frame comes after the last chunk")
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
        try await Task.sleep(for: .milliseconds(150))
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
        chat.speech.synthesize = { text in spoken.append(text); throw CancellationError() }
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
