import XCTest
@testable import IronPetCore

/// The entity store: claims are dated and replaceable, forget and undo keep history, and the prompt and the Markdown export read the
/// same valid claims.
@MainActor
final class EntityMemoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: EntityMemoryStore!
    private var clock = Date(timeIntervalSince1970: 1_795_000_000)
    private var savedExport: URL!
    private var savedLegacy: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-entity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedExport = EntityMemoryStore.exportDirectory
        savedLegacy = LegacyMemoryFiles.directory
        EntityMemoryStore.exportDirectory = dir.appendingPathComponent("memory-export")
        LegacyMemoryFiles.directory = dir.appendingPathComponent("memory")
        store = EntityMemoryStore(database: try Database(path: nil, migrations: AppMigrations.all))
        store.now = { [unowned self] in clock }
    }

    override func tearDown() async throws {
        EntityMemoryStore.exportDirectory = savedExport
        LegacyMemoryFiles.directory = savedLegacy
        try? FileManager.default.removeItem(at: dir)
    }

    private var workspace: ProjectKey {
        ProjectKey(key: "github.com/you/demo", name: "demo", isRepo: true, workspace: URL(fileURLWithPath: "/Users/you/code/demo"))
    }

    private func me(_ text: String, source: String = "chat:a") throws -> MemoryNote {
        try store.remember(text, scope: .me, source: source).get()
    }

    func testTheUsersPageExistsFromTheStart() {
        XCTAssertEqual(store.entities().first?.id, "me")
        XCTAssertEqual(store.entities().count, 1)
        XCTAssertTrue(store.claims(of: "me").isEmpty)
    }

    func testRememberSavesADatedClaimWithItsSource() throws {
        _ = try me("Prefers pnpm over npm.")
        let claim = try XCTUnwrap(store.claims(of: "me").first)
        XCTAssertEqual(claim.text, "Prefers pnpm over npm.")
        XCTAssertEqual(claim.date, MemoryNote.day(clock, calendar: .current))
        XCTAssertEqual(claim.sources, ["chat:a"])
        XCTAssertFalse(claim.pinned)
        XCTAssertEqual(store.recentChanges().first?.action, .added)
    }

    func testTheSameFactTwiceIsOneClaimThatMovesToTodayAndGainsASource() throws {
        _ = try me("Prefers pnpm over npm.", source: "chat:a")
        clock = clock.addingTimeInterval(86_400)
        _ = try me("Prefers pnpm over npm.", source: "chat:b")
        let claims = store.claims(of: "me")
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims.first?.date, MemoryNote.day(clock, calendar: .current))
        XCTAssertEqual(claims.first?.sources, ["chat:a", "chat:b"])
        XCTAssertEqual(store.recentChanges().count, 1, "the second save is not a change")
    }

    func testSecretsAreRefusedAndNothingIsSaved() {
        let result = store.remember("AWS key AKIAIOSFODNN7EXAMPLE", scope: .me, source: "chat:a")
        guard case .failure(let failure) = result else { return XCTFail("a key is refused") }
        XCTAssertTrue(failure.message.contains("not saved"))
        XCTAssertTrue(store.claims(of: "me").isEmpty)
    }

    func testAPersonNeedsANameAndAProjectNeedsAFolder() {
        XCTAssertFalse(store.remember("Likes tea", scope: .people, source: "chat:a").isSuccess)
        XCTAssertFalse(store.remember("Uses Make", scope: .project, source: "chat:a").isSuccess)
    }

    func testPersonIsAStubUntilTheyHaveComeUpTwice() throws {
        _ = try store.remember("Leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        XCTAssertTrue(try XCTUnwrap(store.page("Ana").successValue).entity.isStub)
        _ = try store.remember("Owns auth", scope: .people, person: "ana", source: "chat:b").get()
        let page = try XCTUnwrap(store.page("Ana").successValue)
        XCTAssertFalse(page.entity.isStub)
        XCTAssertEqual(page.claims.map(\.text), ["Owns auth", "Leads payments"])
    }

    func testProjectNotesStayOnTheProjectPage() throws {
        _ = try store.remember("Tests run with swift test", scope: .project, project: workspace, source: "chat:a").get()
        XCTAssertEqual(store.claims(of: "project:github.com/you/demo").map(\.text), ["Tests run with swift test"])
        XCTAssertTrue(store.claims(of: "me").isEmpty)
    }

    func testANewerClaimReplacesTheOneItMakesWrongAndKeepsItInHistory() throws {
        _ = try me("Uses npm")
        _ = try store.replace(["Uses npm"], with: "Uses pnpm", scope: .me, source: "chat:b").get()
        XCTAssertEqual(store.claims(of: "me").map(\.text), ["Uses pnpm"])
        XCTAssertEqual(store.history(of: "me").map(\.text), ["Uses npm"])
        XCTAssertEqual(store.recentChanges().first?.action, .replaced)
    }

    func testReplacingWithAFactAlreadyOnThePageStillRetiresTheOldOne() throws {
        _ = try me("Uses npm")
        _ = try me("Uses pnpm")
        _ = try store.replace(["Uses npm"], with: "Uses pnpm", scope: .me, source: "chat:b").get()
        XCTAssertEqual(store.claims(of: "me").map(\.text), ["Uses pnpm"], "the contradicted fact must not stay valid")
        XCTAssertEqual(store.history(of: "me").map(\.text), ["Uses npm"])
        let forgot = try XCTUnwrap(store.recentChanges().first)
        XCTAssertEqual(forgot.action, .forgot)
        try store.undo(forgot).get()
        XCTAssertEqual(Set(store.claims(of: "me").map(\.text)), ["Uses npm", "Uses pnpm"])
    }

    func testARefusedReplaceLeavesNoMentionOrClaimBehind() throws {
        let old = (0..<6).map { "Old fact \($0)" }
        for text in old { _ = try store.remember(text, scope: .people, person: "Ana", source: "chat:a").get() }
        let mentions = store.entities().first { $0.id == "person:ana" }?.mentions
        XCTAssertFalse(store.replace(old, with: "New", scope: .people, person: "Ana", source: "chat:c").isSuccess)
        XCTAssertEqual(store.entities().first { $0.id == "person:ana" }?.mentions, mentions, "a refused write does not count as a mention")
        XCTAssertEqual(store.claims(of: "person:ana").count, 6)
    }

    func testUndoOfAReplaceBringsTheOldClaimBack() throws {
        _ = try me("Uses npm")
        _ = try store.replace(["Uses npm"], with: "Uses pnpm", scope: .me, source: "chat:b").get()
        let change = try XCTUnwrap(store.recentChanges().first)
        try store.undo(change).get()
        XCTAssertEqual(store.claims(of: "me").map(\.text), ["Uses npm"])
        XCTAssertEqual(store.history(of: "me").map(\.text), ["Uses pnpm"], "the undone claim stays in history, as an undone add does")
        XCTAssertTrue(store.recentChanges().first?.undone == true)
    }

    func testUndoOfAnAddRemovesTheClaim() throws {
        _ = try me("Works in Helsinki")
        try store.undo(try XCTUnwrap(store.recentChanges().first)).get()
        XCTAssertTrue(store.claims(of: "me").isEmpty)
        XCTAssertEqual(store.history(of: "me").map(\.text), ["Works in Helsinki"])
    }

    func testForgetMovesTheMatchesToHistoryAndUndoBringsThemBack() throws {
        _ = try me("Prefers pnpm over npm")
        _ = try me("Works in Helsinki")
        let removed = try store.forget("pnpm", scope: nil, person: nil, project: nil, source: "chat:c").get()
        XCTAssertEqual(removed.map(\.note.text), ["Prefers pnpm over npm"])
        XCTAssertEqual(store.claims(of: "me").map(\.text), ["Works in Helsinki"])
        try store.undo(try XCTUnwrap(store.recentChanges().first)).get()
        XCTAssertEqual(store.claims(of: "me").count, 2)
    }

    func testForgetRefusesWhenNothingMatches() throws {
        _ = try me("Works in Helsinki")
        XCTAssertFalse(store.forget("pnpm", scope: nil, person: nil, project: nil, source: "chat:c").isSuccess)
        XCTAssertEqual(store.claims(of: "me").count, 1)
    }

    func testForgetRefusesMoreThanFiveAndRemovesNothing() throws {
        for n in 0..<6 { _ = try me("Fact \(n) about the same thing") }
        XCTAssertFalse(store.forget("fact", scope: nil, person: nil, project: nil, source: "chat:c").isSuccess)
        XCTAssertEqual(store.claims(of: "me").count, 6)
    }

    func testReplaceRefusesMoreThanFiveAndSavesNothing() throws {
        let old = (0..<6).map { "Old fact \($0)" }
        for text in old { _ = try me(text) }
        XCTAssertFalse(store.replace(old, with: "New", scope: .me, source: "chat:c").isSuccess)
        XCTAssertEqual(store.claims(of: "me").count, 6)
    }

    func testAPinnedClaimIsNotReplacedAndTheNewOneSitsBesideIt() throws {
        _ = try me("Uses npm")
        let claim = try XCTUnwrap(store.claims(of: "me").first)
        XCTAssertTrue(store.setPinned(claim.id, true))
        _ = try store.replace(["Uses npm"], with: "Uses pnpm", scope: .me, source: "chat:b").get()
        XCTAssertEqual(Set(store.claims(of: "me").map(\.text)), ["Uses npm", "Uses pnpm"])
        XCTAssertTrue(store.claims(of: "me").first { $0.text == "Uses npm" }?.pinned == true)
    }

    func testRecallIsNewestFirstAndSaysWhatWasLeftOut() throws {
        _ = try me("First fact")
        clock = clock.addingTimeInterval(3_600)
        _ = try me("Second fact")
        let all = store.recall(.me, project: nil, bytes: 10_000, naming: "")
        XCTAssertEqual(all.components(separatedBy: "\n").first.map { $0.contains("Second fact") }, true)
        let none = store.recall(.me, project: nil, bytes: 1, naming: "")
        XCTAssertEqual(none, "(2 older notes not shown; use memory_search to find them.)")
    }

    func testPeopleNamedInTheMessageComeFirst() throws {
        _ = try store.remember("Leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        _ = try store.remember("Reviews PRs", scope: .people, person: "Bo", source: "chat:a").get()
        _ = try store.remember("Reviews PRs", scope: .people, person: "Bo", source: "chat:a").get()
        let text = store.recall(.people, project: nil, bytes: 10_000, naming: "Draft a note to Ana")
        XCTAssertTrue(text.contains("## Ana\n- Leads payments"))
    }

    func testForgetEverythingKeepsTheUsersPageAndEmptiesTheRest() throws {
        _ = try me("Uses zsh")
        _ = try store.remember("Leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        store.forgetEverything()
        XCTAssertTrue(store.claims(of: "me").isEmpty)
        XCTAssertEqual(store.entities().map(\.id), ["me"])
        XCTAssertTrue(store.recentChanges().isEmpty)
    }

    func testForgetEverythingDeletesTheOldNotesAndTheMarkdownCopies() throws {
        let legacy = LegacyMemoryFiles.directory
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "- Leads payments".write(to: legacy.appendingPathComponent("people.md"), atomically: true, encoding: .utf8)
        _ = try me("Uses zsh")
        let folder = try store.exportMarkdown().get()
        store.forgetEverything()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testReindexRebuildsTheSearchDocumentsFromTheClaims() throws {
        _ = try me("Prefers pnpm over npm")
        XCTAssertEqual(store.index.search("pnpm", kinds: [.note]).count, 1)
        store.index.clearClaims()
        XCTAssertTrue(store.index.search("pnpm", kinds: [.note]).isEmpty)
        store.reindex()
        XCTAssertEqual(store.index.search("pnpm", kinds: [.note]).count, 1)
    }

    func testLinksAreRefusedForAnUnknownName() {
        XCTAssertFalse(store.links("Nobody", type: nil).isSuccess)
    }

    func testExportWritesEachPageAsMarkdown() throws {
        _ = try me("Prefers pnpm over npm")
        _ = try store.remember("Leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        _ = try store.remember("Tests run with swift test", scope: .project, project: workspace, source: "chat:a").get()
        let folder = try store.exportMarkdown().get()
        XCTAssertEqual(folder, EntityMemoryStore.exportDirectory)
        let me = try String(contentsOf: folder.appendingPathComponent("me.md"), encoding: .utf8)
        XCTAssertTrue(me.hasPrefix("# About me\n\n- Prefers pnpm over npm <!--"))
        let people = try String(contentsOf: folder.appendingPathComponent("people.md"), encoding: .utf8)
        XCTAssertTrue(people.contains("## Ana\n\n- Leads payments"))
        let projects = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("projects").path)
        XCTAssertEqual(projects.count, 1)
        XCTAssertTrue(projects.first?.hasPrefix("demo-") == true)
    }

    func testExportNoLongerHoldsANoteThatWasForgotten() throws {
        _ = try store.remember("Leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        _ = try store.remember("Tests run with swift test", scope: .project, project: workspace, source: "chat:a").get()
        _ = try store.exportMarkdown().get()
        _ = try store.forget("payments", scope: .people, person: nil, project: nil, source: "chat:c").get()
        _ = try store.forget("swift test", scope: .project, person: nil, project: workspace, source: "chat:c").get()
        let folder = try store.exportMarkdown().get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("people.md").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("projects").path), [])
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
    var successValue: Success? { if case .success(let value) = self { return value } else { return nil } }
}
