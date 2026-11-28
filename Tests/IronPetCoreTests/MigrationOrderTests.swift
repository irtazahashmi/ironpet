import XCTest
@testable import IronPetCore

/// All stores share one database and one `user_version`, so a migration numbered below one that already ran is skipped on
/// databases that have run it. These tests keep every number unique and in increasing order, and cover the case that broke (#450).
@MainActor
final class MigrationOrderTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-migration-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// Every list that `AppMigrations.all` joins, by name. A new store's list goes here too.
    private var lists: [(name: String, migrations: [Database.Migration])] {
        [("AutomationState", AutomationState.migrations), ("UsageStore", UsageStore.migrations), ("TaskStore", TaskStore.migrations),
         ("CaptureStore", CaptureStore.migrations), ("ActivityLog", ActivityLog.migrations), ("JobService", JobService.migrations),
         ("MemoryIndex", MemoryIndex.migrations), ("NotificationStore", NotificationStore.migrations), ("RemoteStore", RemoteStore.migrations),
         ("RecordRefs", RecordRefs.migrations), ("NodeIdentity", NodeIdentity.migrations), ("AgentRegistry", AgentRegistry.migrations)]
    }

    private func columns(_ database: Database) throws -> Set<String> {
        try database.read { try TaskStore.columns($0, "task_suggestion_resolved") }
    }

    func testEveryListIsInIncreasingOrder() async {
        for list in lists {
            let versions = list.migrations.map(\.version)
            XCTAssertEqual(versions, versions.sorted(), "\(list.name) is not in increasing order")
            XCTAssertEqual(Set(versions).count, versions.count, "\(list.name) repeats a version")
        }
    }

    func testNoVersionIsUsedByTwoStores() async {
        var owner: [Int: String] = [:]
        for list in lists {
            for migration in list.migrations {
                if let other = owner[migration.version] {
                    XCTFail("version \(migration.version) is in \(other) and \(list.name)")
                }
                owner[migration.version] = list.name
            }
        }
    }

    func testTheListsAreTheOnesAppMigrationsJoins() async {
        XCTAssertEqual(lists.flatMap(\.migrations).map(\.version).sorted(), AppMigrations.all.map(\.version).sorted(),
                       "a list is missing from this test or from AppMigrations.all")
    }

    func testADatabaseAtVersion603GetsTheResolvedByColumnAndCanResolve() async throws {
        let file = dir.appendingPathComponent("ironpet.db")
        let before = try Database(path: file, migrations: AppMigrations.all.filter { $0.version <= 603 })
        XCTAssertEqual(before.schemaVersion, 603)
        XCTAssertFalse(try columns(before).contains("resolved_by"))

        let database = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertTrue(try columns(database).contains("resolved_by"))
        let store = TaskStore(database: database)
        let item = try XCTUnwrap(store.suggest([(title: "Merge the lockfile PR", due: nil, waitingOn: nil)],
                                               meeting: URL(string: "file:///meeting.md")!).first)
        let record = try store.resolve(item.id, reason: "You merged it", by: "Mail check")
        XCTAssertEqual(record.resolvedBy, "Mail check")
        XCTAssertEqual(store.resolved().first?.resolvedBy, "Mail check")
    }

    func testAFreshDatabaseHasTheResolvedByColumn() async throws {
        let database = try Database(path: dir.appendingPathComponent("fresh.db"), migrations: AppMigrations.all)
        XCTAssertTrue(try columns(database).contains("resolved_by"))
    }
}
