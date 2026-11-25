import XCTest
@testable import IronPetCore

/// The node id, the agent id and the provenance columns: a fresh and an upgraded database both get a node id that stays across
/// restarts, every write records who made it, and new record ids stay unique when many nodes create them.
@MainActor
final class NodeIdentityTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("ironpet.db") }

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-node-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func column(_ database: Database, _ table: String, _ column: String, where clause: String = "1 = 1") throws -> [String?] {
        try database.read { try $0.rows("SELECT \(column) FROM \(table) WHERE \(clause)").map { $0[0] as? String } }
    }

    // MARK: The node id

    func testAFreshDatabaseGetsANodeIdThatSurvivesRestarts() async throws {
        let first = try Database(path: file, migrations: AppMigrations.all)
        let id = try XCTUnwrap(NodeIdentity.nodeID(in: first))
        XCTAssertTrue(id.hasPrefix("node_"))
        XCTAssertEqual(id.count, "node_".count + 16, "16 hex digits of randomness")
        let second = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(NodeIdentity.nodeID(in: second), id, "a restart keeps the id")
        let rows = try second.read { try $0.rows("SELECT COUNT(*) FROM node_identity") }
        XCTAssertEqual(rows.first?.first as? Int64, 1)
    }

    func testTwoInstallsGetDifferentNodeIds() async throws {
        let a = try Database(path: nil, migrations: AppMigrations.all)
        let b = try Database(path: nil, migrations: AppMigrations.all)
        XCTAssertNotEqual(NodeIdentity.nodeID(in: a), NodeIdentity.nodeID(in: b))
    }

    /// A copy of a database made by main before this change (schema 551) with data in every table that gains columns.
    func testAnUpgradedDatabaseKeepsItsRowsAndGetsANodeId() async throws {
        let before = try Database(path: file, migrations: AppMigrations.all.filter { $0.version <= 551 })
        XCTAssertEqual(before.schemaVersion, 551)
        try before.write { db in
            try db.execute("INSERT INTO task_items(id, title, notes, status, source, created, updated) VALUES('old-task', 'Old', '', 'backlog', 'chat', 1, 1)")
            try db.execute("INSERT INTO task_events(task, at, by, kind, detail) VALUES('old-task', 1, 'chat', 'created', 'backlog: Old')")
            try db.execute("INSERT INTO memory_entities(id, type, name) VALUES('me', 'person', 'Me')")
            try db.execute("INSERT INTO memory_claims(entity, text, ref) VALUES('me', 'Likes tea', 'claim_abcdef')")
            try db.execute("INSERT INTO memory_changes(at, file, action, note, source) VALUES(1, 'me', 'add', 'Likes tea', 'chat')")
            try db.execute("INSERT INTO automation_runs(automation, at, outcome, output) VALUES('watch', 1, 'ok', 'fine')")
            try db.execute("INSERT INTO notification_items(id, created, source, type, title, summary, description) VALUES('n1', 1, 'system', 'other', 'Hi', '', '')")
        }

        let after = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(after.schemaVersion, AppMigrations.latestVersion)
        XCTAssertNotNil(NodeIdentity.nodeID(in: after))
        for (table, key) in [("task_items", "id"), ("task_events", "task"), ("memory_claims", "entity"), ("memory_changes", "file"),
                             ("automation_runs", "automation"), ("notification_items", "id")] {
            XCTAssertEqual(try column(after, table, key).count, 1, "\(table) lost its row")
            XCTAssertEqual(try column(after, table, "node_id"), [nil], "\(table): an old row has no node")
            XCTAssertEqual(try column(after, table, "agent_id"), [nil], "\(table): an old row has no agent")
        }
        XCTAssertEqual(try column(after, "memory_claims", "text"), ["Likes tea"])
    }

    func testTheNodeIdOfAnUpgradedDatabaseSurvivesRestarts() async throws {
        _ = try Database(path: file, migrations: AppMigrations.all.filter { $0.version <= 551 })
        let first = try XCTUnwrap(NodeIdentity.nodeID(in: try Database(path: file, migrations: AppMigrations.all)))
        XCTAssertEqual(NodeIdentity.nodeID(in: try Database(path: file, migrations: AppMigrations.all)), first)
    }

    func testADatabaseWithoutTheNodeTableHasNoNodeIdAndWritesStillWork() async throws {
        let database = try Database(path: nil, migrations: TaskStore.migrations)
        XCTAssertNil(NodeIdentity.nodeID(in: database))
        let store = TaskStore(database: database, keepDoneDays: { 30 })
        _ = try store.create(title: "No node", source: .chat, by: "chat")
        XCTAssertEqual(try column(database, "task_items", "node_id"), [nil])
        XCTAssertEqual(try column(database, "task_items", "agent_id"), [AgentID.default.rawValue])
    }

    // MARK: Provenance on writes

    func testTaskWritesRecordTheNodeAndTheAgent() async throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        let node = try XCTUnwrap(NodeIdentity.nodeID(in: database))
        let store = TaskStore(database: database, keepDoneDays: { 30 })
        let task = try store.create(title: "Write it", source: .agent, by: "agent")
        _ = try store.update(task.id, title: "Write it down", note: "started", by: "agent")
        try store.close(task.id, by: "user")
        XCTAssertEqual(try column(database, "task_items", "node_id"), [node])
        XCTAssertEqual(try column(database, "task_items", "agent_id"), [AgentID.default.rawValue])
        let nodes = try column(database, "task_events", "node_id")
        XCTAssertGreaterThanOrEqual(nodes.count, 3)
        XCTAssertTrue(nodes.allSatisfy { $0 == node }, "every task event names the node")
        XCTAssertTrue(try column(database, "task_events", "agent_id").allSatisfy { $0 == AgentID.default.rawValue })
        try store.delete(task.id, by: "user")
        let deleted = try column(database, "task_events", "node_id", where: "kind = 'deleted'")
        XCTAssertEqual(deleted, [node], "the delete is attributed too")
    }

    func testMemoryWritesRecordTheNodeAndTheAgent() async throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        let node = try XCTUnwrap(NodeIdentity.nodeID(in: database))
        let store = EntityMemoryStore(database: database)
        _ = try store.remember("Drinks tea", scope: .me, source: "chat:a").get()
        let claims = try column(database, "memory_claims", "node_id", where: "text = 'Drinks tea'")
        XCTAssertEqual(claims, [node])
        XCTAssertEqual(try column(database, "memory_claims", "agent_id", where: "text = 'Drinks tea'"), [AgentID.default.rawValue])
        let index = MemoryIndex(database: database)
        index.record(at: Date(), file: "me", section: nil, action: .added, note: "Drinks tea", previous: nil, source: "chat:a")
        let nodes = try column(database, "memory_changes", "node_id")
        XCTAssertFalse(nodes.isEmpty)
        XCTAssertTrue(nodes.allSatisfy { $0 == node }, "every logged memory change names the node")
        XCTAssertTrue(try column(database, "memory_changes", "agent_id").allSatisfy { $0 == AgentID.default.rawValue })
    }

    func testAutomationRunsRecordTheNodeAndTheAgent() async throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        let node = try XCTUnwrap(NodeIdentity.nodeID(in: database))
        let state = AutomationState(database: database)
        state.record("watch", .init(date: Date(), outcome: "ok", output: "fine"))
        XCTAssertEqual(try column(database, "automation_runs", "node_id"), [node])
        XCTAssertEqual(try column(database, "automation_runs", "agent_id"), [AgentID.default.rawValue])
    }

    func testNotificationsRecordTheNodeAndTheAgent() async throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        let node = try XCTUnwrap(NodeIdentity.nodeID(in: database))
        let store = NotificationStore(database: database)
        XCTAssertNotNil(store.add(NotificationDraft(title: "Build finished")))
        XCTAssertEqual(try column(database, "notification_items", "node_id"), [node])
        XCTAssertEqual(try column(database, "notification_items", "agent_id"), [AgentID.default.rawValue])
    }

    // MARK: Ids across nodes

    func testNewIdsHaveTwelveDigitsAndOldOnesStillParse() async throws {
        let made = RecordID.make(.task, taken: { _ in false })
        XCTAssertEqual(RecordID.parse(made)?.hex.count, RecordID.newDigits)
        XCTAssertEqual(RecordID.newDigits, 12)
        XCTAssertEqual(RecordID.parse("task_9f3c1e")?.kind, .task, "a six digit id from before still parses")
    }

    /// Many installs that never talk to each other each create records. No two ids may match, in any kind.
    func testIdsMadeOnManyNodesDoNotCollide() async throws {
        var seen = Set<String>()
        var total = 0
        for _ in 0..<60 {
            let node = try Database(path: nil, migrations: AppMigrations.all)
            let refs = RecordRefs(database: node)
            for kind in [RecordKind.task, .job] {
                let made = refs.refs(kind, (0..<120).map { "key-\($0)" })
                XCTAssertEqual(made.count, 120)
                total += made.count
                seen.formUnion(made.values)
            }
        }
        XCTAssertEqual(seen.count, total, "two nodes made the same id")
    }

    func testOldIdsStillResolveBesideNewOnes() async throws {
        let database = try Database(path: file, migrations: AppMigrations.all.filter { $0.version <= 550 })
        try database.write { db in
            try db.execute("INSERT INTO task_items(id, title, notes, status, source, created, updated) VALUES('fix-login-bug', 'Fix login bug', '', 'backlog', 'chat', 1, 1)")
        }
        let upgraded = try Database(path: file, migrations: AppMigrations.all)
        let refs = RecordRefs(database: upgraded)
        let resolver = RecordResolver(refs: refs)
        let oldRef = try XCTUnwrap(refs.ref(.task, "fix-login-bug"))
        XCTAssertEqual(RecordID.parse(oldRef)?.hex.count, 6, "the ref made by the 551 backfill keeps its six digits")
        let newRef = try XCTUnwrap(refs.ref(.task, "a-new-task"))
        XCTAssertEqual(RecordID.parse(newRef)?.hex.count, 12)
        XCTAssertEqual(try resolver.resolve(oldRef).get().key, "fix-login-bug")
        XCTAssertEqual(try resolver.resolve("fix-login-bug").get().key, "fix-login-bug", "the slug still resolves")
        XCTAssertEqual(try resolver.resolve(newRef).get().key, "a-new-task")
    }

    // MARK: The API

    func testHelloAndTheAPIReportTheNodeId() async throws {
        let rig = try ContractRig()
        XCTAssertNotNil(rig.api.node.info())
        let connection = RPCConnection(deviceID: "cli-1", name: "CLI", kind: .cli, connection: .inProcess)
        let result = try rig.api.session.hello(HelloRequest(protocolVersion: 1, client: ClientInfo(name: "x", version: "1")), connection: connection)
        XCTAssertEqual(result.node, rig.api.node.info())
        XCTAssertEqual(result.node?.agent, AgentID.default.rawValue)
        XCTAssertTrue(result.node?.id.hasPrefix("node_") ?? false)
    }

    func testHelloHasNoNodeWhenTheHostHasNoId() async throws {
        let session = SessionAPI(clients: ClientRegistry(), events: APIEventBus()) { [] }
        let connection = RPCConnection(deviceID: "d", name: "n", kind: .cli, connection: .inProcess)
        let result = try session.hello(HelloRequest(protocolVersion: 1, client: ClientInfo(name: "x", version: "1")), connection: connection)
        XCTAssertNil(result.node)
        let json = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("\"node\""))
    }
}
