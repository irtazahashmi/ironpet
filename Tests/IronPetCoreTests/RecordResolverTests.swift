import XCTest
@testable import IronPetCore

@MainActor
final class RecordResolverTests: XCTestCase {
    private var database: Database!
    private var tasks: TaskStore!
    private var refs: RecordRefs!

    override func setUp() async throws {
        try await super.setUp()
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        tasks = TaskStore(database: database, keepDoneDays: { 30 })
        refs = RecordRefs(database: database)
    }

    override func tearDown() async throws {
        tasks = nil
        refs = nil
        database = nil
        try await super.tearDown()
    }

    private func call(_ name: String, _ args: [String: Any], records: RecordResolver? = nil) async throws -> (text: String, isError: Bool) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                               "params": ["name": name, "arguments": args]])
        let (status, data) = await MCPEndpoint.handle(body, automations: nil, tasks: TasksAPI(store: tasks), records: records)
        XCTAssertEqual(status, "200 OK")
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    /// A database that already ran the newest migration on main (550) must still get the ref table when this build opens it.
    func testADatabaseAlreadyAtFiveFiftyGetsTheRefTable() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("refs-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: path) }
        let old = Database.open(path: path, migrations: AppMigrations.all.filter { $0.version <= 550 })
        XCTAssertNil(old.error)
        let upgraded = Database.open(path: path, migrations: AppMigrations.all)
        XCTAssertNil(upgraded.error)
        let tables = try upgraded.database.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'record_refs'") }
        XCTAssertEqual(tables.count, 1, "the record_refs table is missing after upgrading from 550")
    }

    func testIdsHaveThePrefixAndAtLeastSixHexDigits() async throws {
        XCTAssertEqual(RecordID.parse("task_9f3c1e")?.kind, .task)
        XCTAssertEqual(RecordID.parse("task_9f3c1e")?.hex, "9f3c1e")
        XCTAssertNil(RecordID.parse("task_9f3c1"), "five digits is too few")
        XCTAssertNil(RecordID.parse("task_9F3C1E"), "uppercase is not an id")
        XCTAssertNil(RecordID.parse("fix-login-bug"), "an old id is not in the new form")
        XCTAssertNil(RecordID.parse("job-k3m9qa"), "an old job id is not in the new form")
        XCTAssertNil(RecordID.parse("nope_9f3c1e"), "an unknown prefix is not a kind")
    }

    func testMakeGrowsOnlyWhenEveryTryCollides() async throws {
        let fixed = RecordID.make(.screen, taken: { _ in false }, digit: { "a" })
        XCTAssertEqual(fixed, "screen_aaaaaaaaaaaa")
        var tried = 0
        let grown = RecordID.make(.screen, taken: { _ in tried += 1; return tried <= 8 }, digit: { "b" })
        XCTAssertEqual(grown, "screen_bbbbbbbbbbbbb", "eight collisions at twelve digits make it thirteen")
    }

    func testRefsAreStableAndOnlyCreatedOnce() async throws {
        let first = refs.ref(.task, "fix-login-bug")
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.hasPrefix("task_") ?? false)
        XCTAssertEqual(refs.ref(.task, "fix-login-bug"), first, "the same key keeps its ref")
        XCTAssertEqual(refs.lookup(first ?? "")?.key, "fix-login-bug")
        XCTAssertNil(refs.lookup("task_ffffff"))
    }

    func testResolvesARefAndAnOldIdToTheSameRecord() async throws {
        let ref = try XCTUnwrap(refs.ref(.task, "fix-login-bug"))
        let api = RecordResolver(refs: refs)
        XCTAssertEqual(api.resolve(ref), .success(.init(kind: .task, key: "fix-login-bug", ref: ref)))
        XCTAssertEqual(api.resolve("fix-login-bug"), .success(.init(kind: .task, key: "fix-login-bug", ref: ref)))
    }

    func testAnUnknownIdSaysSo() async throws {
        let api = RecordResolver(refs: refs)
        XCTAssertEqual(api.resolve("task_ffffff"), .failure(RecordError(message: "no record with id task_ffffff")))
        XCTAssertEqual(api.resolve("nothing-here"), .failure(RecordError(message: "no record with id nothing-here")))
    }

    func testAnOldIdShownByTwoKindsAsksForARef() async throws {
        let task = try XCTUnwrap(refs.ref(.task, "shared"))
        let filter = try XCTUnwrap(refs.ref(.filter, "shared"))
        let result = RecordResolver(refs: refs).resolve("shared")
        guard case .failure(let error) = result else { return XCTFail("expected the ambiguity error, got \(result)") }
        XCTAssertTrue(error.message.contains("more than one record"), error.message)
        XCTAssertTrue(error.message.contains(task) && error.message.contains(filter), error.message)
    }

    func testGetReadsATaskByRefAndMatchesTasksGet() async throws {
        let created = try await call("tasks_create", ["title": "Review the release notes", "origin": ["kind": "chat", "ref": "chat-1", "reason": "test"]])
        XCTAssertFalse(created.isError, created.text)
        let ref = try XCTUnwrap(tasks.tasks.first?.ref, "a new task gets a ref")
        XCTAssertTrue(ref.hasPrefix("task_"))

        let records = RecordResolver(refs: refs)
        let byRef = try await call("get", ["id": ref], records: records)
        let byOldID = try await call("get", ["id": "review-the-release-notes"], records: records)
        let direct = try await call("tasks_get", ["id": "review-the-release-notes"])
        XCTAssertFalse(byRef.isError, byRef.text)
        XCTAssertEqual(byRef.text, direct.text, "get returns what tasks_get returns")
        XCTAssertEqual(byOldID.text, direct.text)
        XCTAssertTrue(byRef.text.contains(ref), "the answer names the ref")
    }

    func testGetAnUnknownIdIsAnErrorNotAnEmptyAnswer() async throws {
        let result = try await call("get", ["id": "task_ffffff"], records: RecordResolver(refs: refs))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "no record with id task_ffffff")
    }

    func testGetWithoutRecordsReportsAnError() async throws {
        let result = try await call("get", ["id": "task_ffffff"])
        XCTAssertTrue(result.isError)
    }

    func testGetKindWithoutAReaderSaysSo() async throws {
        let screen = try XCTUnwrap(refs.ref(.screen, "window-1"))
        let result = try await call("get", ["id": screen], records: RecordResolver(refs: refs))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("screen"), result.text)
    }

    func testGetAFilterIdWithoutAFilterInConfigSaysSo() async throws {
        let filter = try XCTUnwrap(refs.ref(.filter, "mine"))
        let result = try await call("get", ["id": filter], records: RecordResolver(refs: refs))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "no quick filter with id mine")
    }

    func testGetIsListedAsAToolWithRequiredID() async throws {
        let tools = RecordMCP.tools
        let get = try XCTUnwrap(tools.first { $0["name"] as? String == "get" })
        XCTAssertEqual((get["inputSchema"] as? [String: Any])?["required"] as? [String], ["id"])
    }
}
