import XCTest
@testable import IronPetCore

@MainActor
final class InboxCLIAndMCPTests: XCTestCase {
    private var store: TaskStore!
    private var api: TasksAPI!
    private var now = Date()

    override func setUp() async throws {
        try await super.setUp()
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, now: { [unowned self] in now })
        api = TasksAPI(store: store)
    }

    private func mcp(_ name: String, _ args: [String: Any]) async throws -> (text: String, isError: Bool) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": name, "arguments": args]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: api)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        return (((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result["isError"] as? Bool ?? false)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func items(_ name: String, _ args: [String: Any] = [:]) async throws -> [[String: Any]] {
        let reply = try await mcp(name, args)
        return try XCTUnwrap(try json(reply.text)["items"] as? [[String: Any]])
    }

    private func isError(_ name: String, _ args: [String: Any]) async throws -> Bool {
        try await mcp(name, args).isError
    }

    private func seed() {
        now = Date().addingTimeInterval(-3 * 86_400)
        store.suggest(.init(key: "m1", title: "Reply to Ana"), agent: .email, sourceRef: "mail:m1")
        now = now.addingTimeInterval(3 * 86_400)
        store.suggest(.init(key: "p1", title: "Review the PR"), agent: .pr, sourceRef: "pr:1")
        store.suggest([(title: "Send the notes", due: nil, waitingOn: nil)], meeting: URL(fileURLWithPath: "/tmp/meeting"))
    }

    // S1

    func testListShowsEveryItemWithItsSourceAndFilters() async throws {
        seed()
        let all = try await items("inbox_list")
        XCTAssertEqual(all.map { $0["source"] as? String }, ["email", "pr", "meeting"])
        let email = try await items("inbox_list", ["source": "email"])
        XCTAssertEqual(email.map { $0["title"] as? String }, ["Reply to Ana"])
        let recent = try await items("inbox_list", ["since": "2d"])
        XCTAssertEqual(recent.map { $0["title"] as? String }, ["Review the PR", "Send the notes"], "the email item is three days old")
        let bad = try await mcp("inbox_list", ["source": "fax"])
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("source must be one of"), bad.text)
    }

    func testCLICommandsBecomeTheMatchingOperations() throws {
        var request = try InboxCLI.request(["list", "--source", "pr", "--since", "2d", "--json"])
        XCTAssertEqual(request.op, "list")
        XCTAssertEqual(request.args as? [String: String], ["source": "pr", "since": "2d"])
        XCTAssertTrue(request.json)
        request = try InboxCLI.request(["list"])
        XCTAssertFalse(request.json)
        request = try InboxCLI.request(["get", "abc"])
        XCTAssertEqual(request.op, "get")
        XCTAssertEqual(request.args as? [String: String], ["id": "abc"])
        request = try InboxCLI.request(["done", "abc"])
        XCTAssertEqual(request.op, "done")
        request = try InboxCLI.request(["remove", "abc", "--note", "duplicate"])
        XCTAssertEqual(request.args as? [String: String], ["id": "abc", "note": "duplicate"])
        request = try InboxCLI.request(["note", "abc", "call", "her", "--soon"])
        XCTAssertEqual(request.args as? [String: String], ["id": "abc", "text": "call her --soon"])
        request = try InboxCLI.request(["add", "--title", "Call Ana", "--notes", "re: date", "--due", "2026-12-01", "--url", "https://example.com"])
        XCTAssertEqual(request.op, "add")
        XCTAssertEqual(request.args["title"] as? String, "Call Ana")
        XCTAssertEqual(request.args["id"] as? String, "cli:call ana")
        XCTAssertThrowsError(try InboxCLI.request(["add"]))
        XCTAssertThrowsError(try InboxCLI.request(["done"]))
        XCTAssertThrowsError(try InboxCLI.request(["list", "--nope", "x"]))
        XCTAssertThrowsError(try InboxCLI.request(["frobnicate"]))
    }

    func testTheCLIEndpointRunsTheSameOperationsAndAnswersJSON() throws {
        seed()
        let body = try JSONSerialization.data(withJSONObject: ["op": "list", "args": ["source": "pr"]])
        let reply = TaskMCP.handleCLI(body, api: api)
        XCTAssertEqual(reply.status, "200 OK")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        let items = try XCTUnwrap((object["result"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(TaskMCP.handleCLI(Data("nope".utf8), api: api).status, "400 Bad Request")
    }

    // S2

    func testDoneOverMCPTakesTheItemOffTheListTheAppShows() async throws {
        seed()
        let id = try XCTUnwrap(api.suggestions.first?.id)
        let done = try await mcp("inbox_done", ["id": id])
        XCTAssertFalse(done.isError, done.text)
        XCTAssertFalse(api.suggestions.contains { $0.id == id })
        XCTAssertEqual(api.suggestions.count, 2)
    }

    // S4

    func testTheCLIAddAndInboxAddReachTheSameStorePath() async throws {
        let added = TaskJSON.call(api, "add", ["id": "cli:call ana", "title": "Call Ana"], by: "cli")
        guard case .success(let value) = added, let result = value as? [String: Any] else { return XCTFail("\(added)") }
        XCTAssertEqual(result["added"] as? Bool, true)
        XCTAssertEqual(api.suggestions.first?.originKind, .cli)
        // The same title from another source is the one item the store already dedupes.
        let origin: [String: Any] = ["kind": "email", "ref": "mail:1", "reason": "Ana wrote"]
        let again = try await mcp("inbox_add", ["id": "mail:1", "title": "Call Ana.", "origin": origin])
        XCTAssertTrue(again.text.contains("\"added\" : false"), again.text)
        XCTAssertEqual(api.suggestions.count, 1)
        // The CLI add of the same title twice is also one item.
        let twice = TaskJSON.call(api, "add", ["id": "cli:call ana", "title": "Call Ana"], by: "cli")
        guard case .success(let second) = twice else { return XCTFail("\(twice)") }
        XCTAssertEqual((second as? [String: Any])?["added"] as? Bool, false)
        // An agent still has to give an origin.
        let missing = try await mcp("inbox_add", ["id": "x", "title": "No origin"])
        XCTAssertTrue(missing.isError)
    }

    // S5

    func testGetShowsOriginAndHistoryAndNoteAddsToIt() async throws {
        seed()
        let id = try XCTUnwrap(api.suggestions.first { $0.title == "Reply to Ana" }?.id)
        let beforeReply = try await mcp("inbox_get", ["id": id])
        let item = try XCTUnwrap(try json(beforeReply.text)["item"] as? [String: Any])
        XCTAssertEqual(item["source"] as? String, "email")
        XCTAssertNotNil(item["source_ref"], "the origin the agent gave")
        XCTAssertEqual((item["history"] as? [[String: Any]])?.map { $0["event"] as? String }, ["created"])

        let noted = try await mcp("inbox_note", ["id": id, "text": "Waiting for her date"])
        XCTAssertFalse(noted.isError, noted.text)
        let afterReply = try await mcp("inbox_get", ["id": id])
        let after = try XCTUnwrap(try json(afterReply.text)["item"] as? [String: Any])
        let history = try XCTUnwrap(after["history"] as? [[String: Any]])
        XCTAssertEqual(history.map { $0["event"] as? String }, ["created", "note"])
        XCTAssertEqual(history.last?["text"] as? String, "Waiting for her date")
        XCTAssertEqual(history.last?["by"] as? String, "agent:mcp")
        XCTAssertTrue(api.suggestions.contains { $0.id == id }, "a note does not take the item off the list")

        let missingGet = try await isError("inbox_get", ["id": "missing"])
        let emptyNote = try await isError("inbox_note", ["id": id, "text": "   "])
        let missingNote = try await isError("inbox_note", ["id": "missing", "text": "x"])
        XCTAssertTrue(missingGet)
        XCTAssertTrue(emptyNote)
        XCTAssertTrue(missingNote)
    }

    func testNotesGoWhenTheItemDoes() async throws {
        seed()
        let id = try XCTUnwrap(api.suggestions.first?.id)
        _ = try await mcp("inbox_note", ["id": id, "text": "keep"])
        XCTAssertEqual(api.notes(for: id).count, 1)
        _ = try await mcp("inbox_done", ["id": id])
        XCTAssertEqual(api.notes(for: id), [])
    }

    func testTheToolListNamesTheNewToolsAndKeepsTheOldOnes() throws {
        let names = Set(TaskMCP.tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["inbox_list", "inbox_get", "inbox_note", "inbox_add", "inbox_done", "inbox_remove", "inbox_resolve"])
        XCTAssertTrue(ApprovalRules.ownTaskTools.isSuperset(of: names))
    }
}
