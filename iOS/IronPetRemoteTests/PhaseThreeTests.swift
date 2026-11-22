import IronPetKit
import XCTest
@testable import IronPetRemote

private func waitUntil(_ timeout: Double = 30, _ condition: @escaping @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// The chat model against the mock server: streaming, uploads, reconnects and the Mac's refusals.
@MainActor
final class ChatModelTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    private func model(_ client: IronPetClient) -> ChatModel {
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        return ChatModel(client: client, events: events, onUnauthorized: {})
    }

    private func started() async -> ChatModel {
        let model = model(client())
        model.start()
        await waitUntil { model.loaded && model.snapshot != nil }
        return model
    }

    func testTheChatLoadsItsTranscriptAndHeader() async {
        let model = await started()
        XCTAssertEqual(model.title, "Fix the login test")
        XCTAssertEqual(model.items.map(\.id), ["m-1", "m-2"])
        XCTAssertEqual(model.subtitle, "Claude Code · demo-app · Idle")
        model.stop()
    }

    func testStreamedChunksEndWithTheFullText() async {
        let model = await started()
        var expected = ""
        for index in 1...50 {
            expected += "w\(index) "
            server.streamChunk(item: "m-stream", "w\(index) ")
        }
        await waitUntil { model.items.last?.text == expected }
        XCTAssertEqual(model.items.last?.text, expected)
        XCTAssertEqual(model.items.filter { $0.id == "m-stream" }.count, 1, "one bubble for the whole stream")
        model.stop()
    }

    // S16
    func testAPhotoUploadsFirstAndTheSendCarriesItsId() async throws {
        let model = await started()
        let photo = Data(repeating: 3, count: 4_000)
        model.attach(data: photo, fileName: "photo-1.jpg", contentType: "image/jpeg")
        model.draft = "look at this"
        await model.send()
        let lines = server.requests.map(\.line).filter { $0 == "POST /v1/uploads" || $0 == "POST /v1/chat/current/messages" }
        XCTAssertEqual(lines, ["POST /v1/uploads", "POST /v1/chat/current/messages"], "the upload comes first")
        let upload = try XCTUnwrap(server.requests.first { $0.path == "/v1/uploads" })
        XCTAssertEqual(upload.body, photo)
        let send = try XCTUnwrap(server.requests.last { $0.path == "/v1/chat/current/messages" })
        let ids = try XCTUnwrap(send.json["upload_ids"] as? [String])
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(server.uploaded(ids[0]), photo)
        XCTAssertEqual(send.json["text"] as? String, "look at this")
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertFalse(model.sentPhotos.isEmpty, "the phone keeps its photo to draw a thumbnail")
        model.stop()
    }

    func testAFailedUploadSendsNothingAndKeepsTheDraft() async {
        let model = await started()
        server.uploadFails = true
        model.attach(data: Data(repeating: 1, count: 10), fileName: "a.png", contentType: "image/png")
        model.draft = "see"
        await model.send()
        XCTAssertEqual(server.count("POST /v1/chat/current/messages"), 0)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.draft, "see")
        XCTAssertEqual(model.attachments.count, 1)
        model.stop()
    }

    func testAFileOverTwentyMegabytesIsRefusedBeforeUploading() async {
        let model = await started()
        model.attach(data: Data(count: ChatModel.maxUploadBytes + 1), fileName: "big.mov", contentType: "video/quicktime")
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        model.stop()
    }

    func testAReplyIsSentWithTheQuotedItemId() async throws {
        let model = await started()
        model.replyTo = model.items[1]
        model.draft = "why?"
        await model.send()
        let send = try XCTUnwrap(server.requests.last { $0.path == "/v1/chat/current/messages" })
        XCTAssertEqual((send.json["reply"] as? [String: Any])?["item_id"] as? String, "m-2")
        XCTAssertNil(model.replyTo)
        model.stop()
    }

    // S17
    func testResyncReloadsTheChatAndAConflictBecomesAnAlertMessage() async {
        let model = await started()
        let before = server.count("GET /v1/chat/current")
        server.chat.title = "Renamed on the Mac"
        server.publish(RemoteEvent.resync)
        let server = server!
        await waitUntil { server.count("GET /v1/chat/current") > before && model.title == "Renamed on the Mac" }
        XCTAssertEqual(model.title, "Renamed on the Mac")

        server.openConflict = "The agent is working. Stop it first, or wait for it to finish."
        await model.loadThreads()
        let thread = try? XCTUnwrap(model.threads.first)
        let opened = await model.open(thread!)
        XCTAssertFalse(opened)
        XCTAssertEqual(model.conflictMessage, "The agent is working. Stop it first, or wait for it to finish.")
        let fresh = await model.newChat()
        XCTAssertFalse(fresh)
        model.conflictMessage = nil
        server.openConflict = nil
        let ok = await model.open(thread!)
        XCTAssertTrue(ok)
        XCTAssertNil(model.conflictMessage)
        model.stop()
    }

    func testAnApprovalCardGoesWhenTheMacSaysItIsGone() async {
        let model = await started()
        server.chat.approvals = [RemoteApproval(id: "ap-1", title: "Run npm test", detail: "npm test")]
        server.publish(RemoteEvent.chatState, id: "approvals")
        await waitUntil { model.approvals.count == 1 }
        XCTAssertEqual(model.approvals.map(\.id), ["ap-1"])
        server.chat.approvals = []
        server.publish(RemoteEvent.chatState, id: "approvals")
        await waitUntil { model.approvals.isEmpty }
        XCTAssertTrue(model.approvals.isEmpty, "another client answered it")
        model.stop()
    }

    func testAnApprovalIsDecidedWithAllowTrue() async throws {
        let model = await started()
        server.chat.approvals = [RemoteApproval(id: "ap-1", title: "Run npm test")]
        server.publish(RemoteEvent.chatState, id: "approvals")
        await waitUntil { model.approvals.count == 1 }
        await model.decide(model.approvals[0], allow: true)
        XCTAssertEqual(try XCTUnwrap(server.requests.last { $0.path == "/v1/chat/approvals/ap-1" }).json["allow"] as? Bool, true)
        XCTAssertTrue(model.approvals.isEmpty)
        model.stop()
    }

    func testAnUnknownKindShowsAsAnUnsupportedRowAndDoesNotBreakTheList() async {
        server.chat.items.insert(RemoteChatItem(id: "m-sys", kind: "system", text: "Automation ran"), at: 1)
        let model = await started()
        XCTAssertEqual(model.items.count, 3)
        XCTAssertEqual(model.items[1].row, .unsupported("Automation ran"))
        model.stop()
    }

    func testTheMarkdownOfAReplyIsInterpretedInline() {
        let text = MessageRow.markdown("The **fixture** is `stale`.")
        XCTAssertEqual(String(text.characters), "The fixture is stale.")
    }
}

/// The agent's own permission modes in the chat settings: the phone lists what the agent advertises and sends the picked id back.
@MainActor
final class ChatModeTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func started() async -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.start()
        await waitUntil { model.loaded && model.snapshot != nil }
        return model
    }

    func testPickingAModeSendsItsIdAndTheModelShowsTheOneInForce() async throws {
        server.chat.options.modes = [.init(id: "default", name: "Default"), .init(id: "acceptEdits", name: "Accept edits"), .init(id: "plan", name: "Plan")]
        server.chat.options.mode = "default"
        let model = await started()
        XCTAssertEqual(model.snapshot?.options.modes.map(\.id), ["default", "acceptEdits", "plan"])
        XCTAssertEqual(model.snapshot?.options.mode, "default")
        let done = await model.setOptions(RemoteChatOptionsChange(mode: "plan"))
        XCTAssertTrue(done)
        XCTAssertEqual(try XCTUnwrap(server.requests.last { $0.line == "PATCH /v1/chat/options" }).json["mode"] as? String, "plan")
        XCTAssertEqual(model.snapshot?.options.mode, "plan", "the sheet shows what the Mac now reports")
        model.stop()
    }

    func testAnAgentWithoutModesSendsNoneAndTheModelStillLoads() async {
        let model = await started()
        XCTAssertEqual(model.snapshot?.options.modes, [])
        XCTAssertNil(model.snapshot?.options.mode)
        model.stop()
    }
}
