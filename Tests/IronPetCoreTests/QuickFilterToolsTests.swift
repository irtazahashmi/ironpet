import XCTest
@testable import IronPetCore
import struct IronPetKit.QuickFilter

/// The quick filter tools an agent sees: `task_filters_*` and the `filter` and `query` arguments of `tasks_list`.
@MainActor
final class QuickFilterToolsTests: XCTestCase {
    private var store: TaskStore!
    private var config: ConfigStore!
    private var api: TasksAPI!

    override func setUp() async throws {
        try await super.setUp()
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, keepDoneDays: { 30 })
        config = ConfigStore(memory: Config())
        api = TasksAPI(store: store, config: config)
        let origin: [String: Any] = ["kind": "chat", "ref": "chat-1", "reason": "test"]
        _ = try await call("tasks_create", ["title": "Plan the epic launch", "labels": ["project": "epic"], "origin": origin])
        _ = try await call("tasks_create", ["title": "Finish epic docs", "labels": ["project": "epic"], "origin": origin])
        _ = try await call("tasks_create", ["title": "Band rehearsal", "labels": ["project": "band"], "origin": origin])
        _ = try await call("tasks_close", ["id": "finish-epic-docs", "note": "done"])
    }

    @discardableResult
    private func call(_ name: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: api)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private func titles(_ arguments: [String: Any]) async throws -> Set<String> {
        let listed = try await call("tasks_list", arguments)
        XCTAssertFalse(listed.isError, listed.text)
        return Set((try json(listed.text)["tasks"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String })
    }

    private let epicOpen: [String: Any] = ["and": [["label": ["project": "epic"]], ["not": ["status": "done"]]]]

    func testTheToolsAreListedWithTheQuerySchema() async throws {
        let names = Set(TaskMCP.tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["task_filters_list", "task_filters_upsert", "task_filters_delete", "task_filters_reorder"]))
        let upsert = try XCTUnwrap(TaskMCP.tools.first { $0["name"] as? String == "task_filters_upsert" })
        let description = try XCTUnwrap(upsert["description"] as? String)
        for word in ["and", "or", "not", "label", "labelExists", "status", "waitingOn", "due", "source", "text", "overdue"] {
            XCTAssertTrue(description.contains("\"\(word)\""), "the description documents \(word)")
        }
        let list = try XCTUnwrap(TaskMCP.tools.first { $0["name"] as? String == "tasks_list" })
        let properties = try XCTUnwrap((list["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(properties["filter"])
        XCTAssertNotNil(properties["query"])
    }

    // S2
    func testAnInvalidQueryIsRefusedWithTheBadNodeAndNothingIsStored() async throws {
        let bad: [(Any, String)] = [
            (["color": "red"], "query: unknown condition \"color\""),
            (["and": [["status": "done"], ["status": "finished"]]], "query.and[1].status"),
            (["and": []], "query.and: must be a non-empty array"),
            (["or": []], "query.or: must be a non-empty array"),
            (["not": ["labelExists": 3]], "query.not.labelExists"),
            ("{not json", "not JSON"),
        ]
        for (query, expected) in bad {
            let result = try await call("task_filters_upsert", ["name": "Broken", "query": query])
            XCTAssertTrue(result.isError, "\(query)")
            XCTAssertTrue(result.text.contains(expected), "\(query): \(result.text)")
        }
        XCTAssertEqual(api.quickFilters, [])
        XCTAssertEqual(config.config.tasks.quickFilters, [])
    }

    func testUpsertListDeleteAndListingByFilter() async throws {
        let created = try await call("task_filters_upsert", ["name": "Epic, open", "query": epicOpen])
        XCTAssertFalse(created.isError, created.text)
        let id = try XCTUnwrap(try json(created.text)["id"] as? String)
        XCTAssertEqual(id, "epic-open")
        XCTAssertEqual(config.config.tasks.quickFilters.map(\.id), ["epic-open"], "stored in config.json, so the phone gets settings.changed")

        let listed = try json(try await call("task_filters_list", [:]).text)
        let filters = try XCTUnwrap(listed["filters"] as? [[String: Any]])
        XCTAssertEqual(filters.map { $0["name"] as? String }, ["Epic, open"])
        XCTAssertNotNil(filters.first?["query"] as? [String: Any])

        let everything = try await titles(["include_done": true])
        XCTAssertEqual(everything, ["Plan the epic launch", "Finish epic docs", "Band rehearsal"])
        let byFilter = try await titles(["filter": id])
        XCTAssertEqual(byFilter, ["Plan the epic launch"], "the filter leaves out the done epic task and the band task")
        let inline = try await titles(["query": ["label": ["project": "band"]]])
        XCTAssertEqual(inline, ["Band rehearsal"])
        let both = try await titles(["filter": id, "query": ["text": "docs"]])
        XCTAssertEqual(both, [], "filter and query combine with and")
        let missing = try await call("tasks_list", ["filter": "nope"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("no quick filter with id \"nope\""))

        let removed = try await call("task_filters_delete", ["id": id])
        XCTAssertFalse(removed.isError, removed.text)
        let after = try json(try await call("task_filters_list", [:]).text)
        XCTAssertEqual((after["filters"] as? [Any])?.count, 0)
        let refused1 = try await call("task_filters_delete", ["id": id]).isError
        XCTAssertTrue(refused1, "a second delete says it is gone")
    }

    func testUpsertWithAnIdChangesThatFilterAndNamesStayUnique() async throws {
        _ = try await call("task_filters_upsert", ["name": "Epic", "query": ["label": ["project": "epic"]]])
        _ = try await call("task_filters_upsert", ["name": "Band", "query": ["label": ["project": "band"]]])
        let changed = try await call("task_filters_upsert", ["id": "epic", "name": "Epic work", "query": ["text": "epic"]])
        XCTAssertFalse(changed.isError, changed.text)
        XCTAssertEqual(api.quickFilters.map(\.name), ["Epic work", "Band"], "an edit keeps its place")
        let refused2 = try await call("task_filters_upsert", ["name": "band", "query": ["text": "x"]]).isError
        XCTAssertTrue(refused2, "names are unique without regard to case")
        let refused3 = try await call("task_filters_upsert", ["name": "All", "query": ["text": "x"]]).isError
        XCTAssertTrue(refused3, "All is the chip that clears the filter")
        let refused4 = try await call("task_filters_upsert", ["name": "  ", "query": ["text": "x"]]).isError
        XCTAssertTrue(refused4)

        let reordered = try await call("task_filters_reorder", ["ids": ["band"]])
        XCTAssertFalse(reordered.isError, reordered.text)
        XCTAssertEqual(api.quickFilters.map(\.id), ["band", "epic"])
        XCTAssertEqual(api.quickFilters.map(\.order), [0, 1])
        let refused5 = try await call("task_filters_reorder", ["ids": ["ghost"]]).isError
        XCTAssertTrue(refused5)
    }

    func testAQueryGivenAsAJSONStringIsAccepted() async throws {
        let created = try await call("task_filters_upsert", ["name": "Band", "query": #"{"label":{"project":"band"}}"#])
        XCTAssertFalse(created.isError, created.text)
        let result = try await titles(["filter": "band"])
        XCTAssertEqual(result, ["Band rehearsal"])
    }

    func testAGeneratedIdFromANonASCIINameCanBeSentBackToEdit() async throws {
        let created = try await call("task_filters_upsert", ["name": "Café", "query": ["text": "x"]])
        XCTAssertFalse(created.isError, created.text)
        let id = try XCTUnwrap(api.quickFilters.first?.id)
        let edited = try await call("task_filters_upsert", ["id": id, "name": "Café open", "query": ["text": "y"]])
        XCTAssertFalse(edited.isError, edited.text)
        XCTAssertEqual(api.quickFilters.map(\.name), ["Café open"])
    }

    func testTheCLIBuildsTheFilterRequests() throws {
        XCTAssertEqual(try TaskCLI.request(["filters"]).op, "filters_list")
        let set = try TaskCLI.request(["filter-set", "Epic", "open", "--query", #"{"text":"epic"}"#, "--id", "epic"])
        XCTAssertEqual(set.op, "filters_upsert")
        XCTAssertEqual(set.args["name"] as? String, "Epic open")
        XCTAssertEqual(set.args["id"] as? String, "epic")
        XCTAssertEqual(try TaskCLI.request(["filter-delete", "epic"]).args["id"] as? String, "epic")
        XCTAssertEqual(try TaskCLI.request(["filter-order", "b", "a"]).args["ids"] as? [String], ["b", "a"])
        let list = try TaskCLI.request(["list", "--filter", "epic", "--query", "{}"])
        XCTAssertEqual(list.args["filter"] as? String, "epic")
    }

    func testFiltersPersistInConfigAndAnOlderFileWithoutThemStillLoads() throws {
        var next = Config()
        next.tasks.quickFilters = [QuickFilter(id: "a", name: "A", query: .object(["text": .string("x")]), order: 0)]
        let data = try JSONEncoder().encode(next)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data).tasks.quickFilters, next.tasks.quickFilters)
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any]
        let tasks = try XCTUnwrap(defaults?["tasks"] as? [String: Any])
        XCTAssertEqual((tasks["quickFilters"] as? [Any])?.count, 0)
    }
}
