import XCTest
@testable import IronPetCore

/// The one-time move of the markdown notes of earlier builds onto entity pages. The files stay on disk and nothing reads them again.
@MainActor
final class MemoryMigrationTests: XCTestCase {
    private var dir: URL!
    private var folder: URL!
    private var store: EntityMemoryStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-migration-\(UUID().uuidString)")
        folder = dir.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("projects"), withIntermediateDirectories: true)
        store = EntityMemoryStore(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, _ path: String) throws {
        try text.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func writeOldFiles() throws {
        try write("# About me\n\n- Prefers pnpm <!-- 2026-11-01 chat:a -->\n", "me.md")
        try write("# People\n\n## Ana\n\n- Leads payments <!-- 2026-11-02 meeting:x -->\n", "people.md")
        try write("# demo\n\nRepo: github.com/you/demo\n\n- Tests run with swift test <!-- 2026-11-03 chat:b -->\n", "projects/demo-0a1b2c3d.md")
    }

    func testEachOldNoteBecomesAClaimOnItsPage() async throws {
        try writeOldFiles()
        XCTAssertEqual(MemoryMigration.run(into: store, folder: folder), 3)
        XCTAssertEqual(store.claims(of: "me").map(\.text), ["Prefers pnpm"])
        XCTAssertEqual(store.claims(of: "me").first?.date, "2026-11-01")
        XCTAssertEqual(store.claims(of: "me").first?.sources, ["chat:a"])
        let ana = try XCTUnwrap(store.page("Ana").successValue)
        XCTAssertEqual(ana.claims.map(\.text), ["Leads payments"])
        XCTAssertEqual(ana.claims.first?.sources, ["meeting:x"])
        XCTAssertFalse(ana.entity.isStub, "a person from the old file already came up often enough to be named")
        XCTAssertEqual(store.claims(of: "project:github.com/you/demo").map(\.text), ["Tests run with swift test"])
    }

    func testTheMigrationRunsOnceAndLeavesTheFilesAlone() async throws {
        try writeOldFiles()
        _ = MemoryMigration.run(into: store, folder: folder)
        XCTAssertEqual(MemoryMigration.run(into: store, folder: folder), 0, "a second launch writes nothing")
        XCTAssertEqual(store.claims(of: "me").count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("me.md").path), "the old file stays on disk")
    }

    func testAFolderWithNoFilesStillRecordsTheRun() async {
        XCTAssertEqual(MemoryMigration.run(into: store, folder: folder), 0)
        XCTAssertNotNil(store.index.cursor(MemoryMigration.doneKey))
    }

    func testANoteAlreadyOnThePageIsNotAddedTwice() async throws {
        _ = try store.remember("Prefers pnpm", scope: .me, source: "chat:z").get()
        try writeOldFiles()
        XCTAssertEqual(MemoryMigration.run(into: store, folder: folder), 2, "the me note is already there")
        XCTAssertEqual(store.claims(of: "me").count, 1)
    }
}

private extension Result {
    var successValue: Success? { if case .success(let value) = self { return value } else { return nil } }
}
