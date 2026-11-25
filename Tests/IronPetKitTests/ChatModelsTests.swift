import XCTest
@testable import IronPetKit

final class ChatModelsTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    func paired() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    // S13
    func testAnUnknownKindBetweenTwoKnownItemsDecodesAsAPlainRow() throws {
        let json = """
        {"title":"t","state":"idle","running":false,"folder_label":"demo","agent":{"id":"claude","name":"Claude Code"},
         "items":[{"id":"1","kind":"user","text":"hi","date":"2026-01-01T10:00:00Z","origin":"ios"},
                  {"id":"2","kind":"system","text":"Automation ran at 10:00","extra":{"nested":[1,2]}},
                  {"id":"3","kind":"assistant","text":"hello"}],
         "approvals":[],"forms":[],"queue":[]}
        """
        let snapshot = try WireJSON.makeDecoder().decode(RemoteChatSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.items.count, 3)
        XCTAssertEqual(snapshot.items.map(\.row), [.user("hi"), .unsupported("Automation ran at 10:00"), .assistant("hello")])
        XCTAssertEqual(snapshot.items[0].origin, "ios")
    }

    func testAnItemWithoutTextOrKindStillMakesARow() throws {
        let json = #"{"id":"1","kind":"hologram"}"#
        let item = try WireJSON.makeDecoder().decode(RemoteChatItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.row, .unsupported(""))
        XCTAssertFalse(item.canReply)
    }

    func testABrokenItemIsSkippedInsteadOfFailingTheList() throws {
        let json = #"{"items":[{"id":"1","kind":"user","text":"a"},{"kind":"user"},{"id":"3","kind":"assistant","text":"b"}]}"#
        let snapshot = try WireJSON.makeDecoder().decode(RemoteChatSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.items.map(\.id), ["1", "3"])
    }

    func testEveryKnownKindMapsToItsRow() throws {
        let kinds: [(RemoteChatItem, RemoteChatRow)] = [
            (RemoteChatItem(id: "a", kind: "tool", text: "Ran ls", ok: true), .tool("Ran ls", ok: true)),
            (RemoteChatItem(id: "b", kind: "error", text: "Boom"), .error("Boom")),
            (RemoteChatItem(id: "c", kind: "screenshot", fileName: "x.png", isImage: true), .attachment(fileName: "x.png", isImage: true)),
            (RemoteChatItem(id: "d", kind: "form", text: "Which?", skipped: false, lines: [RemoteFormLine(question: "Pick", answer: "A")]),
             .form(message: "Which?", skipped: false, lines: [RemoteFormLine(question: "Pick", answer: "A")])),
        ]
        for (item, row) in kinds { XCTAssertEqual(item.row, row) }
    }

    func testFormAnswersKeepTheirType() throws {
        let json = #"{"id":"f","message":"m","fields":[{"id":"p","title":"P","detail":"","required":true,"type":"single","options":[{"value":"a","title":"A","detail":""}]}],"answers":{"p":"a","t":["x","y"],"s":true},"can_submit":true}"#
        let form = try WireJSON.makeDecoder().decode(RemoteForm.self, from: Data(json.utf8))
        XCTAssertEqual(form.answers, ["p": .text("a"), "t": .list(["x", "y"]), "s": .flag(true)])
        XCTAssertEqual(form.fields.first?.options?.first?.title, "A")
        XCTAssertTrue(form.canSubmit)
    }

    func testReadsTheChatAndOneMessage() async throws {
        let snapshot = try await paired().chat()
        XCTAssertEqual(snapshot.title, "Fix the login test")
        XCTAssertEqual(snapshot.items.count, 2)
        let item = try await paired().chatMessage(id: "m-2")
        XCTAssertEqual(item.row, .assistant("The **fixture** is stale."))
    }

    func testSendsAMessageWithUploadsAndAReply() async throws {
        let result = try await paired().sendMessage(text: "see this", uploadIDs: ["up-1"], reply: RemoteReplyRef(itemID: "m-2", selectionText: "fixture"))
        XCTAssertEqual(result.outcome, "sent")
        let body = try XCTUnwrap(server.requests.last).json
        XCTAssertEqual(body["text"] as? String, "see this")
        XCTAssertEqual(body["upload_ids"] as? [String], ["up-1"])
        XCTAssertEqual((body["reply"] as? [String: Any])?["item_id"] as? String, "m-2")
        XCTAssertEqual((body["reply"] as? [String: Any])?["selection_text"] as? String, "fixture")
    }

    func testUploadsTheBytesAndTheEncodedFileName() async throws {
        let bytes = Data(repeating: 9, count: 200_000)
        let upload = try await paired().upload(bytes, fileName: "my photo.jpg", contentType: "image/jpeg")
        XCTAssertEqual(upload.fileName, "my photo.jpg")
        XCTAssertEqual(server.uploaded(upload.id), bytes)
        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.headers["content-type"], "image/jpeg")
        XCTAssertEqual(request.headers["x-file-name"], "my%20photo%2Ejpg")
    }

    func testAConflictCarriesTheMacsMessage() async throws {
        server.openConflict = "The agent is working. Stop it first."
        do { try await paired().openThread(id: "th-1"); XCTFail("expected 409") } catch {
            guard case .api(let status, _, let message) = error as? ClientError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "The agent is working. Stop it first.")
        }
    }

    func testThreadsListAndRead() async throws {
        let threads = try await paired().chatThreads()
        XCTAssertEqual(threads.map(\.id), ["th-1", "th-2"])
        let detail = try await paired().chatThread(id: "th-1")
        XCTAssertEqual(detail.thread.title, "Old chat")
        XCTAssertEqual(detail.items.map(\.row), [.user("Old question"), .assistant("Old answer")])
    }

    func testDecidesAnApproval() async throws {
        server.chat.approvals = [RemoteApproval(id: "ap-1", title: "Run npm test")]
        try await paired().decide(approval: "ap-1", allow: true)
        XCTAssertEqual(try XCTUnwrap(server.requests.last).json["allow"] as? Bool, true)
        XCTAssertTrue(server.chat.approvals.isEmpty)
    }

    func testChatOptionsDecodeAndAChangeEncodesOnlyWhatItSets() throws {
        let raw = #"{"title":"t","options":{"agents":[{"id":"claude","name":"Claude Code"}],"models":[{"id":"m1","name":"One"}],"folders":[{"id":"/a/web","name":"web"}],"folder":"/a/web","modes":[{"id":"default","name":"Default","detail":"Asks first"},{"id":"plan","name":"Plan"}],"mode":"plan"}}"#
        let snapshot = try JSONDecoder().decode(RemoteChatSnapshot.self, from: Data(raw.utf8))
        XCTAssertEqual(snapshot.options.agents.map(\.id), ["claude"])
        XCTAssertEqual(snapshot.options.models.map(\.name), ["One"])
        XCTAssertEqual(snapshot.options.folder, "/a/web")
        XCTAssertEqual(snapshot.options.modes.map(\.id), ["default", "plan"])
        XCTAssertEqual(snapshot.options.modes.first?.detail, "Asks first")
        XCTAssertEqual(snapshot.options.mode, "plan")
        let old = try JSONDecoder().decode(RemoteChatSnapshot.self, from: Data(#"{"title":"t"}"#.utf8))
        XCTAssertEqual(old.options, RemoteChatOptions(), "a Mac without the options still decodes")

        XCTAssertEqual(RemoteChatOptionsChange(mode: "plan").json as NSDictionary, ["mode": "plan"])
        XCTAssertEqual(RemoteChatOptionsChange(model: .some(nil)).json as NSDictionary, ["model": NSNull()])
        XCTAssertEqual(RemoteChatOptionsChange(model: .some("m1")).json as NSDictionary, ["model": "m1"])
        XCTAssertEqual(RemoteChatOptionsChange(noProject: true).json as NSDictionary, ["no_project": true])
        XCTAssertTrue(RemoteChatOptionsChange().json.isEmpty)
    }
}

final class RemoteFormPagingTests: XCTestCase {
    private func questions(_ count: Int, required: Bool = true) -> RemoteForm {
        var fields: [RemoteFormField] = []
        for n in 0..<count {
            fields.append(RemoteFormField(id: "question_\(n)", title: "Which colour \(n)?", required: required, type: "single",
                                          options: [RemoteFormOption(value: "red", title: "Red"), RemoteFormOption(value: "blue", title: "Blue")]))
            fields.append(RemoteFormField(id: "question_\(n)_custom", title: "Other", type: "text"))
        }
        return RemoteForm(id: "f", message: "m", fields: fields)
    }

    func testEachQuestionIsOnePageWithItsOtherField() {
        let pages = questions(3).pages
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[1].map(\.id), ["question_1", "question_1_custom"])
    }

    func testFormsThatAreNotQuestionsStayOnOnePage() {
        let form = RemoteForm(id: "f", message: "m", fields: [RemoteFormField(id: "name", type: "text"), RemoteFormField(id: "question_1", type: "text")])
        XCTAssertEqual(form.pages.count, 1)
        XCTAssertFalse(ElicitationPager(pageCount: form.pages.count).isPaged)
    }

    func testSingleQuestionIsNotPaged() {
        XCTAssertFalse(ElicitationPager(pageCount: questions(1).pages.count).isPaged)
    }

    func testSubmitJumpsToTheFirstUnansweredRequiredQuestion() {
        var form = questions(3)
        XCTAssertEqual(form.firstIncompletePage(), 0)
        form.answers = ["question_0": .text("red"), "question_2": .text("blue")]
        XCTAssertEqual(form.firstIncompletePage(), 1)
        XCTAssertNil(form.firstIncompletePage(typed: ["question_1": "green"]))
        form.answers["question_1"] = .text("red")
        XCTAssertNil(form.firstIncompletePage())
    }

    func testTypedTextThatIsEmptyStaysIncomplete() {
        var form = questions(2)
        form.fields[0].type = "text"
        form.answers = ["question_0": .text("kept"), "question_1": .text("red")]
        XCTAssertEqual(form.firstIncompletePage(typed: ["question_0": "  "]), 0)
    }

    func testPagerWalksForwardAndBackAndStopsAtTheEnds() {
        var pager = ElicitationPager(pageCount: 3)
        XCTAssertEqual(pager.label, "1 of 3")
        XCTAssertFalse(pager.canGoBack)
        pager.back()
        XCTAssertEqual(pager.index, 0)
        pager.forward(); pager.forward(); pager.forward()
        XCTAssertEqual(pager.label, "3 of 3")
        XCTAssertTrue(pager.isLast)
        pager.show(1)
        XCTAssertEqual(pager.label, "2 of 3")
    }
}
