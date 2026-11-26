import Foundation
import XCTest
import IronPetKit
@testable import IronPetCore

/// A task is assigned to the user (no assignee) or to one agent. Each change is a task event, and an unknown agent id is refused.
@MainActor
final class TaskAssigneeTests: XCTestCase {
    private var database: Database!
    private var store: TaskStore!
    private var api: TasksAPI!
    private let agentB = "agent_bbbb"

    override func setUp() async throws {
        try await super.setUp()
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        try AgentRegistryRows.add(agentB, number: 2, to: database)
        store = TaskStore(database: database, keepDoneDays: { 30 })
        store.registry = AgentRegistry(database: database)
        api = TasksAPI(store: store)
    }

    private func call(_ op: String, _ args: [String: Any]) -> Result<Any, TaskError> {
        TaskJSON.call(api, op, args, by: "agent:mcp")
    }

    private func origin() -> [String: Any] { ["kind": "agent", "ref": "test", "reason": "test"] }

    private func events(_ id: String) throws -> [(kind: String, detail: String, node: String?, agent: String?)] {
        try database.read { db in
            try db.rows("SELECT kind, detail, node_id, agent_id FROM task_events WHERE task = ? ORDER BY id", [id]).map {
                ($0[0] as? String ?? "", $0[1] as? String ?? "", $0[2] as? String, $0[3] as? String)
            }
        }
    }

    // MARK: S1, assign and reassign

    func testAssigningToAnAgentAndBackToTheUserRecordsTwoEvents() async throws {
        let id = try store.create(title: "Review the PR", source: .user, by: "user").id
        XCTAssertNil(store.task(id)?.assignee)

        try store.update(id, assignee: .some(agentB), by: "agent:mcp")
        XCTAssertEqual(store.task(id)?.assignee, agentB)
        try store.update(id, assignee: .some(nil), by: "agent:mcp")
        XCTAssertNil(store.task(id)?.assignee)

        let changes = try events(id).filter { $0.detail.hasPrefix("assignee:") }
        XCTAssertEqual(changes.map(\.detail), ["assignee: user → \(agentB)", "assignee: \(agentB) → user"])
        let node = try database.read { try $0.rows("SELECT node_id FROM node_identity").first?.first as? String }
        XCTAssertNotNil(node)
        XCTAssertEqual(changes.map(\.node), [node, node])
        XCTAssertEqual(changes.map(\.agent), [AgentOwner.defaultID, AgentOwner.defaultID])
    }

    func testAssigningTheSameAssigneeAgainAddsNoEvent() async throws {
        let id = try store.create(title: "Same", source: .user, assignee: agentB, by: "user").id
        let before = try events(id).count
        try store.update(id, assignee: .some(agentB), by: "user")
        try store.update(id, assignee: .some("user"), by: "user")
        try store.update(id, assignee: .some(""), by: "user")
        XCTAssertEqual(try events(id).count, before + 1, "only the hand back to the user is a change")
    }

    func testAssigningOverMCPAndBack() async throws {
        guard case .success(let created) = call("create", ["title": "Over MCP", "origin": origin()]),
              let id = (created as? [String: Any])?["id"] as? String else { return XCTFail("create failed") }
        guard case .success(let assigned) = call("update", ["id": id, "changes": ["assignee": agentB]]) else { return XCTFail("assign failed") }
        XCTAssertEqual((assigned as? [String: Any])?["assignee"] as? String, agentB)
        guard case .success(let back) = call("update", ["id": id, "changes": ["assignee": ""]]) else { return XCTFail("hand back failed") }
        XCTAssertNil((back as? [String: Any])?["assignee"], "a task with no assignee leaves the key out: it is the user's")
        XCTAssertEqual(try events(id).filter { $0.detail.hasPrefix("assignee:") }.count, 2)
    }

    func testAssigningOverTheTypedAPI() async throws {
        let id = try api.create(CreateTaskRequest(title: "Typed", source: .user, assignee: agentB)).id
        XCTAssertEqual(api.task(id)?.assignee, agentB)
        try api.update(UpdateTaskRequest(id: id, assignee: "user"))
        XCTAssertNil(api.task(id)?.assignee)
        let history = try api.get(id).history.map(\.detail)
        XCTAssertTrue(history.contains("assignee: \(agentB) → user"))
        XCTAssertTrue(history.first?.contains("[assignee: \(agentB)]") == true, "the created event names the first assignee")
    }

    // MARK: S2, an unknown agent

    func testAnUnknownAgentIsNotFoundAndNothingChanges() async throws {
        XCTAssertThrowsError(try api.create(CreateTaskRequest(title: "Nope", source: .user, assignee: "agent_missing"))) { error in
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
        XCTAssertTrue(api.items.isEmpty)

        let id = try store.create(title: "Stays", source: .user, by: "user").id
        let before = try events(id).count
        XCTAssertThrowsError(try api.update(UpdateTaskRequest(id: id, title: "Renamed", assignee: "agent_missing"))) { error in
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
        XCTAssertEqual(api.task(id)?.title, "Stays")
        XCTAssertEqual(try events(id).count, before)
    }

    func testAnUnknownAgentIsRefusedOverMCP() async {
        guard case .failure(let error) = call("create", ["title": "Nope", "origin": origin(), "assignee": "agent_missing"]) else {
            return XCTFail("create succeeded")
        }
        XCTAssertEqual(error.message, "no agent with id \"agent_missing\"")
        XCTAssertTrue(api.items.isEmpty)
    }

    func testADisabledAgentIsKnownAndADeletedOneIsNot() async throws {
        try AgentRegistry(database: database).update(agentB, AgentRecordPatch(enabled: false))
        let id = try store.create(title: "Parked", source: .user, assignee: agentB, by: "user").id
        XCTAssertEqual(store.task(id)?.assignee, agentB)
        try AgentRegistry(database: database).delete(agentB)
        XCTAssertThrowsError(try store.update(id, assignee: .some(agentB), by: "user"))
    }

    func testWithoutARegistryOnlyAgentOneIsKnown() async throws {
        let lone = TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database)
        XCTAssertEqual(try lone.create(title: "One", source: .user, assignee: AgentOwner.defaultID, by: "user").assignee, AgentOwner.defaultID)
        XCTAssertThrowsError(try lone.create(title: "Two", source: .user, assignee: agentB, by: "user"))
    }

    func testAgentOneIsNotTheUser() async throws {
        let id = try store.create(title: "Agent one's", source: .user, assignee: AgentOwner.defaultID, by: "user").id
        XCTAssertEqual(store.task(id)?.assignee, AgentOwner.defaultID)
        XCTAssertEqual(api.list(TaskListRequest(assignee: "user")).count, 0)
    }

    // MARK: S3, the filter

    func testListFiltersByAssignee() async throws {
        let a = try store.create(title: "For one", source: .user, assignee: AgentOwner.defaultID, by: "user").id
        let b = try store.create(title: "For two", source: .user, assignee: agentB, by: "user").id
        let me = try store.create(title: "For me", source: .user, by: "user").id

        XCTAssertEqual(Set(api.list(TaskListRequest(assignee: AgentOwner.defaultID)).map(\.id)), [a])
        XCTAssertEqual(Set(api.list(TaskListRequest(assignee: agentB)).map(\.id)), [b])
        XCTAssertEqual(Set(api.list(TaskListRequest(assignee: "user")).map(\.id)), [me])
        XCTAssertEqual(Set(api.list(TaskListRequest(assignee: "")).map(\.id)), [me])
        XCTAssertEqual(Set(api.list(TaskListRequest()).map(\.id)), [a, b, me])
        XCTAssertEqual(api.list(TaskListRequest(assignee: "agent_missing")).count, 0)
    }

    func testTheMCPListFiltersByAssignee() async throws {
        let b = try store.create(title: "For two", source: .user, assignee: agentB, by: "user").id
        let me = try store.create(title: "For me", source: .user, by: "user").id
        func listed(_ args: [String: Any]) -> [String] {
            guard case .success(let value) = call("list", args), let tasks = (value as? [String: Any])?["tasks"] as? [[String: Any]] else { return ["failed"] }
            return tasks.compactMap { $0["id"] as? String }.sorted()
        }
        XCTAssertEqual(listed(["assignee": agentB]), [b])
        XCTAssertEqual(listed(["assignee": "user"]), [me])
        XCTAssertEqual(listed([:]), [b, me].sorted())
        XCTAssertEqual(listed(["assignee": NSNull()]), [b, me].sorted())
    }

    // MARK: S4, older clients and old databases

    func testAnUpdateWithoutTheFieldKeepsTheAssignee() async throws {
        let id = try store.create(title: "Kept", source: .user, assignee: agentB, by: "user").id
        try api.update(UpdateTaskRequest(id: id, title: "Kept, renamed"))
        XCTAssertEqual(api.task(id)?.assignee, agentB)
        XCTAssertTrue(call("update", ["id": id, "changes": ["notes": "more"]]).isSuccess)
        XCTAssertEqual(api.task(id)?.assignee, agentB)
    }

    func testARequestWithoutAnAssigneeDecodes() async throws {
        let create = try JSONDecoder().decode(CreateTaskRequest.self, from: Data(#"{"title":"Old","notes":"","status":"backlog","source":"user","links":[],"labels":{},"by":"user"}"#.utf8))
        XCTAssertNil(create.assignee)
        let update = try JSONDecoder().decode(UpdateTaskRequest.self, from: Data(#"{"id":"old","clearDue":false,"labels":{},"removeLabels":[],"by":"user"}"#.utf8))
        XCTAssertNil(update.assignee)
        let list = try JSONDecoder().decode(TaskListRequest.self, from: Data(#"{"includeDone":false,"labels":{}}"#.utf8))
        XCTAssertNil(list.assignee)
    }

    func testTasksFromBeforeTheMigrationBelongToTheUser() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-assignee-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        var old: Database? = try Database(path: file, migrations: AppMigrations.all.filter { $0.version < 572 })
        try old?.write { db in
            try db.execute("""
                INSERT INTO task_items(id, title, notes, status, source, created, updated) VALUES('old-task', 'Old task', '', 'backlog', 'user', 1, 1)
                """)
            try db.execute("INSERT INTO task_events(task, at, by, kind, detail) VALUES('old-task', 1, 'user', 'created', 'backlog: Old task')")
        }
        old = nil

        let upgraded = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertGreaterThanOrEqual(upgraded.schemaVersion, 572)
        let tasks = TaskStore(database: upgraded, keepDoneDays: { 30 })
        XCTAssertNil(tasks.task("old-task")?.assignee)
        XCTAssertEqual(tasks.history("old-task").count, 1, "no event is lost")
        XCTAssertEqual(TasksAPI(store: tasks).list(TaskListRequest(assignee: "user")).map(\.id), ["old-task"])
    }

    // MARK: S5, what the Mac shows

    func testTheMacShowsYouOrTheAgentsName() async throws {
        let agents = api.agents
        XCTAssertEqual(agents.map(\.id).sorted(), [AgentOwner.defaultID, agentB].sorted())
        XCTAssertEqual(TaskAssignee.name(nil, agents: agents), "You")
        XCTAssertEqual(TaskAssignee.name(agentB, agents: agents), "Agent 2")
        XCTAssertEqual(TaskAssignee.name(AgentOwner.defaultID, agents: agents), "Ghost")
        XCTAssertEqual(TaskAssignee.name("agent_gone", agents: agents), "agent_gone", "a deleted agent shows its id")
    }

    func testThePickerListsTheUserThenEveryAgentAndKeepsADeletedOne() async {
        let agents = api.agents
        XCTAssertEqual(TaskAssignee.choices(current: nil, agents: agents).map(\.name), ["You", "Ghost", "Agent 2"])
        XCTAssertEqual(TaskAssignee.choices(current: nil, agents: agents).first?.id, nil)
        XCTAssertEqual(TaskAssignee.choices(current: "agent_gone", agents: agents).last?.id, "agent_gone")
    }

    func testChangingTheAssigneeInTheDetailUpdatesTheTaskAndAddsTheEvent() async throws {
        let id = try api.create(CreateTaskRequest(title: "Detail edit", source: .user)).id
        try TaskEdits.setAssignee(agentB, of: id, in: api)
        XCTAssertEqual(api.task(id)?.assignee, agentB)
        try TaskEdits.setAssignee(nil, of: id, in: api)
        XCTAssertNil(api.task(id)?.assignee)
        XCTAssertEqual(api.history(id).map(\.detail).filter { $0.hasPrefix("assignee:") }, ["assignee: user → \(agentB)", "assignee: \(agentB) → user"])
        XCTAssertThrowsError(try TaskEdits.setAssignee("agent_missing", of: id, in: api))
    }

    func testTheRemoteTaskCarriesTheAssigneeOnlyWhenSet() async throws {
        let mine = RemoteTask(try store.create(title: "Mine", source: .user, by: "user"))
        let theirs = RemoteTask(try store.create(title: "Theirs", source: .user, assignee: agentB, by: "user"))
        XCTAssertNil(mine.assignee)
        XCTAssertEqual(theirs.assignee, agentB)
        let encoded = try JSONEncoder().encode(mine)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("assignee"))
        XCTAssertEqual(try JSONDecoder().decode(RemoteTask.self, from: JSONEncoder().encode(theirs)).assignee, agentB)
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

private enum AgentRegistryRows {
    static func add(_ id: String, number: Int, to database: Database) throws {
        try database.write { db in
            try db.execute("INSERT INTO agents(id, number, name, agent_cli, created, updated) VALUES(?, ?, ?, 'claude', 0, 0)", [id, number, "Agent \(number)"])
        }
    }
}
