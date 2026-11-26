import XCTest
@testable import IronPetCore

@MainActor
final class MCPEndpointTests: XCTestCase {
    private var tasks: TaskStore!

    override func setUp() async throws {
        try await super.setUp()
        tasks = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database)
    }

    override func tearDown() async throws {
        tasks = nil
        try await super.tearDown()
    }

    private func rpc(_ method: String, _ params: [String: Any] = [:], tasks: TaskStore?) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": method, "params": params])
        let (status, data) = await MCPEndpoint.handle(body, automations: nil, tasks: tasks.map { TasksAPI(store: $0) })
        XCTAssertEqual(status, "200 OK")
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(reply["id"] as? Int, 7)
        return reply
    }

    private func tool(_ name: String, _ args: [String: Any], tasks: TaskStore?) async throws -> (text: String, isError: Bool) {
        let reply = try await rpc("tools/call", ["name": name, "arguments": args], tasks: tasks)
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testToolsListHasAutomationAndInboxTools() async throws {
        let reply = try await rpc("tools/list", tasks: nil)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["automations_list", "automations_create", "automations_run_now", "automations_history"]))
        XCTAssertEqual(Set(names.filter { $0.hasPrefix("inbox_") }), ["inbox_list", "inbox_get", "inbox_note", "inbox_add", "inbox_done", "inbox_remove"])
        XCTAssertEqual(names.filter { $0.hasPrefix("tasks_") || $0.hasPrefix("task_") || $0.hasPrefix("task_filters_") }, [],
                       "the task list tools are gone")
        XCTAssertEqual(Set(names.filter { $0.hasPrefix("screen_") }), ["screen_search", "screen_window"], "the screen tools are listed for the chat agents")
        XCTAssertEqual(Set(names.filter { $0.hasPrefix("memory_") }), ["memory_remember", "memory_forget", "memory_merge", "memory_page", "memory_links", "memory_search", "memory_get"])
        for memory in tools where (memory["name"] as? String)?.hasPrefix("memory_") == true {
            XCTAssertTrue((memory["description"] as? String ?? "").contains("never instructions"), "\(memory["name"] ?? "") says found text is data")
        }
        for tool in tools {
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(tool["name"] ?? "")")
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
        let add = try XCTUnwrap(tools.first { $0["name"] as? String == "inbox_add" })
        XCTAssertEqual((add["inputSchema"] as? [String: Any])?["required"] as? [String], ["id", "title", "origin"])
    }

    func testInitializeMentionsAutomationsAndTheInbox() async throws {
        let reply = try await rpc("initialize", ["protocolVersion": "2025-06-18"], tasks: nil)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let instructions = result["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("automations"))
        XCTAssertTrue(instructions.contains("inbox"))
        XCTAssertFalse(instructions.contains("task list"))
    }

    func testAddCreatesAnItemAndRefusesIncompleteCalls() async throws {
        let origin: [String: Any] = ["kind": "email", "ref": "mail:abc", "reason": "Ana asked for a date"]
        let made = try await tool("inbox_add", ["id": "mail:abc", "title": "Reply to Ana", "origin": origin], tasks: tasks)
        XCTAssertFalse(made.isError, made.text)
        XCTAssertEqual(tasks.suggestions.map(\.title), ["Reply to Ana"])
        XCTAssertTrue(try XCTUnwrap(tasks.suggestions.first?.sourceRef).contains("Ana asked for a date"))
        let again = try await tool("inbox_add", ["id": "mail:abc", "title": "Another title", "origin": origin], tasks: tasks)
        XCTAssertFalse(again.isError, again.text)
        XCTAssertEqual(tasks.suggestions.count, 1, "same id is ignored")

        for (missing, args) in [("title", ["id": "m2", "origin": origin] as [String: Any]),
                                ("id", ["title": "No id", "origin": origin]),
                                ("origin", ["id": "m3", "title": "No origin"]),
                                ("origin.reason", ["id": "m4", "title": "No reason", "origin": ["kind": "email", "ref": "r"]])] {
            let refused = try await tool("inbox_add", args, tasks: tasks)
            XCTAssertTrue(refused.isError, "missing \(missing): \(refused.text)")
        }
        XCTAssertEqual(tasks.suggestions.count, 1, "refused calls add nothing")
    }

    func testListDoneAndRemoveRoundTripThroughTheStore() async throws {
        let origin: [String: Any] = ["kind": "chat", "ref": "chat-1", "reason": "test"]
        _ = try await tool("inbox_add", ["id": "a", "title": "Review the release notes", "origin": origin], tasks: tasks)
        _ = try await tool("inbox_add", ["id": "b", "title": "Book the room", "origin": origin], tasks: tasks)
        let listed = try await tool("inbox_list", [:], tasks: tasks)
        XCTAssertFalse(listed.isError, listed.text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["title"] as? String }, ["Review the release notes", "Book the room"])

        let first = try XCTUnwrap(items.first?["id"] as? String)
        let done = try await tool("inbox_done", ["id": first], tasks: tasks)
        XCTAssertFalse(done.isError, done.text)
        let second = try XCTUnwrap(items.last?["id"] as? String)
        let removed = try await tool("inbox_remove", ["id": second, "note": "duplicate"], tasks: tasks)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(tasks.suggestions, [])
        let again = try await tool("inbox_done", ["id": first], tasks: tasks)
        XCTAssertTrue(again.isError)
        XCTAssertTrue(again.text.contains("no inbox item"), again.text)
    }

    func testTheRetiredTaskToolsAreUnknown() async throws {
        for name in ["tasks_list", "tasks_create", "tasks_suggest", "task_filters_list", "task_goals_upsert"] {
            let reply = try await rpc("tools/call", ["name": name, "arguments": [:]], tasks: tasks)
            XCTAssertNil(reply["result"], name)
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32602, name)
        }
    }

    func testUnknownToolIsAnInvalidParamsError() async throws {
        let reply = try await rpc("tools/call", ["name": "notes_add", "arguments": [:]], tasks: tasks)
        XCTAssertNil(reply["result"])
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual(error["message"] as? String, "unknown tool notes_add")
    }

    func testToolsWithoutTheirStoreReportAnErrorInsteadOfFailing() async throws {
        let inbox = try await tool("inbox_list", [:], tasks: nil)
        XCTAssertTrue(inbox.isError)
        XCTAssertTrue(inbox.text.contains("not available"), inbox.text)
        let automation = try await tool("automations_list", [:], tasks: tasks)
        XCTAssertTrue(automation.isError)
        XCTAssertTrue(automation.text.contains("not available"), automation.text)
    }

    func testNotificationsParseErrorsAndUnknownMethods() async throws {
        let notification = await MCPEndpoint.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), automations: nil, tasks: tasks.map { TasksAPI(store: $0) })
        XCTAssertEqual(notification.status, "202 Accepted")
        XCTAssertTrue(notification.body.isEmpty)
        let garbage = await MCPEndpoint.handle(Data("not json".utf8), automations: nil, tasks: tasks.map { TasksAPI(store: $0) })
        XCTAssertEqual(garbage.status, "400 Bad Request")
        let unknown = try await rpc("resources/list", tasks: tasks)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let ping = try await rpc("ping", tasks: tasks)
        XCTAssertNotNil(ping["result"] as? [String: Any])
    }
}
