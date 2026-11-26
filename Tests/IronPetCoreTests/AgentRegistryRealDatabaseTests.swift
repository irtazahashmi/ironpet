import XCTest
@testable import IronPetCore

/// S1: a copy of a real `ironpet.db` made by main upgrades through the step 1 and step 2 migrations without losing a row, and today's
/// chat agent becomes agent 1. The copy is personal data, so it stays in `/Users/Shared/feat-297-agents-table`, this test copies it
/// again to a temporary folder before it opens anything, and it reports counts and schema only. It skips where the file is absent,
/// which includes CI.
@MainActor
final class AgentRegistryRealDatabaseTests: XCTestCase {
    static let source = URL(fileURLWithPath: "/Users/Shared/feat-297-agents-table/ironpet-copy.db")

    private func tableCounts(_ database: Database) throws -> [String: Int64] {
        try database.read { db in
            var counts: [String: Int64] = [:]
            for row in try db.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
                guard let name = row[0] as? String else { continue }
                if let count = (try? db.rows("SELECT COUNT(*) FROM \"\(name)\""))?.first?.first as? Int64 { counts[name] = count }
            }
            return counts
        }
    }

    func testARealDatabaseUpgradesKeepingEveryRowAndAgentOneAppears() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.source.path), "no real database copy on this machine")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("ironpet.db")
        try FileManager.default.copyItem(at: Self.source, to: file)

        // The copy as it is: no migration runs on it.
        let before = try Database(path: file, migrations: [])
        let versionBefore = before.schemaVersion
        let counts = try tableCounts(before)
        let node = NodeIdentity.nodeID(in: before)
        XCTAssertFalse(counts.isEmpty)
        XCTAssertNil(try before.read { try $0.rows("SELECT name FROM sqlite_master WHERE name = 'agents'") }.first, "the copy has no agents table yet")

        // The normal path: every migration the app has, step 1 (552 to 560) and step 2 (570).
        let after = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(after.schemaVersion, AppMigrations.latestVersion)
        XCTAssertGreaterThan(after.schemaVersion, versionBefore)
        let countsAfter = try tableCounts(after)
        var report = "schema \(versionBefore) -> \(after.schemaVersion)\n"
        // Migration 590 drops the task tables and the task refs, and rebuilds the suggestions without the rows the tasks needed.
        let changedOn590: Set<String> = ["task_items", "task_links", "task_events", "task_labels", "task_due_marks", "task_scan_cursors",
                                         "task_projects", "task_areas", "task_goals", "task_key_results", "task_suggestions", "record_refs"]
        for table in counts.keys.sorted() {
            if changedOn590.contains(table) { report += "\(table) \(counts[table] ?? -1) -> \(countsAfter[table] ?? -1) (migration 590)\n"; continue }
            XCTAssertEqual(countsAfter[table], counts[table], "\(table) changed its row count")
            report += "\(table) \(counts[table] ?? -1) -> \(countsAfter[table] ?? -1)\n"
        }
        XCTAssertEqual(countsAfter["agents"], 1, "agents is the one new table, with one row")
        XCTAssertEqual(NodeIdentity.nodeID(in: after), node, "step 1's node id is kept")

        let registry = AgentRegistry(database: after)
        let agents = registry.list()
        XCTAssertEqual(agents.count, 1)
        let agent = try XCTUnwrap(agents.first)
        XCTAssertEqual(agent.id, AgentID.default.rawValue)
        XCTAssertEqual(agent.number, 1)
        report += "agents: id \(agent.id), number \(agent.number), name \(agent.name), cli \(agent.agentCli), model \(agent.model ?? "nil")\n"

        // The settings of the user who made the copy are in `UserDefaults` and `config.json`, outside this file. Adopting them is a
        // separate, one-time step, and a second open of the migrated file must change nothing.
        let again = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(try tableCounts(again), countsAfter)
        XCTAssertEqual(AgentRegistry(database: again).list(), agents)
        print("S1 real database upgrade\n" + report)
    }
}
