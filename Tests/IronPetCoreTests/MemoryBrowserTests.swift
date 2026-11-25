import IronPetKit
import XCTest
@testable import IronPetCore

/// The Memory section's read side against a temp store with invented data: the list and its order, search and chips, the page detail,
/// the navigation stack, and pin and forget by id.
@MainActor
final class MemoryBrowserTests: XCTestCase {
    private var dir: URL!
    private var store: EntityMemoryStore!
    private var clock = Date(timeIntervalSince1970: 1_795_000_000)
    private var savedExport: URL!
    private var savedLegacy: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-browser-\(UUID().uuidString)")
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

    private var project: ProjectKey {
        ProjectKey(key: "git.example.test/lighthouse", name: "Lighthouse", isRepo: true, workspace: URL(fileURLWithPath: "/tmp/lighthouse"))
    }

    private func day(_ offset: Int) { clock = Date(timeIntervalSince1970: 1_795_000_000 + Double(offset) * 86_400) }

    /// Me (2 facts), Lighthouse (2 facts), Maya Chen and Zoë Álvarez (people), Maya Cheng (1 fact) and a stub with none.
    private func seed() throws {
        day(0)
        _ = try store.remember("Works from Lisbon.", scope: .me, source: "chat:a").get()
        day(1)
        _ = try store.remember("Database migrations are one-way.", scope: .project, project: project, source: "chat:a").get()
        _ = try store.remember("CI size limit is 64 MB.", scope: .project, project: project, source: "screen").get()
        day(2)
        _ = try store.remember("Owns the Lighthouse repository.", scope: .people, person: "Maya Chen", source: "tasks").get()
        _ = try store.remember("Reviews every release build.", scope: .people, person: "Maya Chen", source: "meeting:2026-11-20-1000").get()
        day(3)
        _ = try store.remember("Wrote the design notes.", scope: .people, person: "Zoë Álvarez", source: "chat:b").get()
        _ = try store.remember("Said the booking intent rose.", scope: .people, person: "Maya Cheng", source: "chat:b").get()
    }

    private func page(_ name: String) throws -> MemoryEntity {
        try XCTUnwrap(store.entities().first { $0.name == name })
    }

    // MARK: S1 list

    func testTheListHoldsEveryPageWithAFactNewestUpdateFirst() async throws {
        try seed()
        _ = store.entities() // a stub with no fact
        let rows = store.browseRows()
        XCTAssertEqual(Set(rows.map(\.name)), ["About me", "Lighthouse", "Maya Chen", "Zoë Álvarez", "Maya Cheng"])
        // Newest update first: the pages written on day 3 lead, About me (day 0) is last.
        XCTAssertEqual(rows.last?.name, "About me")
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.name == "Lighthouse" }).factCount, 2)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.name == "About me" }).type, .me)
        XCTAssertTrue(rows.allSatisfy { $0.ref.hasPrefix("page_") })
    }

    func testThePinnedFactIsTheSummaryElseTheNewest() async throws {
        try seed()
        var lighthouse = try XCTUnwrap(store.browseRows().first { $0.name == "Lighthouse" })
        XCTAssertEqual(lighthouse.summary, "CI size limit is 64 MB.", "the newest fact when nothing is pinned")
        let older = try XCTUnwrap(store.claims(of: try page("Lighthouse").id).first { $0.text.hasPrefix("Database") })
        XCTAssertTrue(store.setPinned(older.id, true))
        lighthouse = try XCTUnwrap(store.browseRows().first { $0.name == "Lighthouse" })
        XCTAssertEqual(lighthouse.summary, "Database migrations are one-way.")
    }

    func testAPageWithNoFactIsHidden() async throws {
        try seed()
        let lighthouse = try page("Lighthouse")
        XCTAssertTrue(store.forgetPage(lighthouse.id, source: "user"))
        XCTAssertNil(store.browseRows().first { $0.name == "Lighthouse" })
    }

    // MARK: S2 search

    func testTheChipNarrowsAndTheSearchIgnoresCaseAndAccents() async throws {
        try seed()
        let rows = store.browseRows()
        let people = MemoryBrowser.list(rows, filter: .people, query: "")
        XCTAssertEqual(people.rows.count, 3)
        XCTAssertEqual(people.countLabel, "3 people")
        let zoe = MemoryBrowser.list(rows, filter: .people, query: "ZOE alvarez")
        XCTAssertEqual(zoe.rows.map(\.name), ["Zoë Álvarez"])
        XCTAssertEqual(zoe.countLabel, "1 of 3 people")
    }

    func testNameMatchesComeFirstThenFactMatchesAndTheSummaryShowsTheMatch() async throws {
        try seed()
        let rows = store.browseRows()
        let result = MemoryBrowser.list(rows, filter: .people, query: "maya")
        XCTAssertEqual(result.rows.map(\.name).prefix(2).sorted(), ["Maya Chen", "Maya Cheng"])
        XCTAssertEqual(result.countLabel, "2 of 3 people")
        // "lighthouse" is in Lighthouse's name and in Maya Chen's fact: the name match leads, the fact match follows.
        let mixed = MemoryBrowser.list(rows, filter: .all, query: "lighthouse")
        XCTAssertEqual(mixed.rows.first?.name, "Lighthouse")
        let maya = try XCTUnwrap(mixed.rows.first { $0.name == "Maya Chen" })
        XCTAssertTrue(maya.matchedInFact)
        XCTAssertEqual(maya.summary, "Owns the Lighthouse repository.")
    }

    func testNoMatchGivesNoRowsAndCountsOtherChips() async throws {
        try seed()
        let rows = store.browseRows()
        XCTAssertTrue(MemoryBrowser.list(rows, filter: .projects, query: "maya").rows.isEmpty)
        let others = MemoryBrowser.otherMatches(rows, query: "maya", excluding: .projects)
        XCTAssertEqual(others.first { $0.filter == .people }?.count, 2)
    }

    // MARK: S3 detail

    func testThePageDetailHasPinnedFirstEarlierAndGroupedLinks() async throws {
        try seed()
        let lighthouse = try page("Lighthouse"), maya = try page("Maya Chen")
        let facts = store.claims(of: lighthouse.id)
        let older = try XCTUnwrap(facts.first { $0.text.hasPrefix("Database") })
        store.setPinned(older.id, true)
        day(5)
        _ = try store.replace(["CI size limit is 64 MB."], with: "CI size limit is 70 MB.", scope: .project, project: project, source: "chat:c").get()
        XCTAssertTrue(store.link(from: maya.id, to: lighthouse.id, type: "works_on", source: "chat:a"))
        let detail = try XCTUnwrap(store.detail(lighthouse.ref))
        XCTAssertEqual(detail.facts.first?.text, "Database migrations are one-way.", "pinned on top")
        XCTAssertTrue(detail.facts.first?.pinned ?? false)
        XCTAssertEqual(detail.earlier.map(\.text), ["CI size limit is 64 MB."])
        XCTAssertEqual(detail.linkGroups.map(\.title), ["Worked on by"])
        XCTAssertEqual(detail.linkGroups.first?.items.first?.name, "Maya Chen")
        let person = try XCTUnwrap(store.detail(maya.id))
        XCTAssertEqual(person.linkGroups.map(\.title), ["Works on"])
        XCTAssertEqual(person.possibleDuplicates.map(\.name), ["Maya Cheng"])
        XCTAssertNil(store.detail("page_missing"))
    }

    // MARK: S4 navigation

    func testTheStackGrowsPopsAndGoesBack() async {
        var nav = MemoryNavigation()
        nav.push("a"); nav.push("b"); nav.push("c")
        XCTAssertEqual(nav.stack, ["a", "b", "c"])
        nav.push("c")
        XCTAssertEqual(nav.stack.count, 3, "the page on top is not pushed twice")
        nav.pop(to: 0)
        XCTAssertEqual(nav.stack, ["a"])
        nav.push("b")
        nav.back()
        XCTAssertEqual(nav.current, "a")
        nav.back()
        XCTAssertFalse(nav.isOpen)
        nav.back()
        XCTAssertFalse(nav.isOpen)
        nav.push("x"); nav.reset()
        XCTAssertTrue(nav.stack.isEmpty)
        nav = MemoryNavigation(stack: ["a", "gone", "c"])
        nav.prune { $0 != "gone" }
        XCTAssertEqual(nav.stack, ["a"])
    }

    // MARK: S5 writes

    func testForgetOneFactKeepsItInTheLogAndPinSticks() async throws {
        try seed()
        let lighthouse = try page("Lighthouse")
        let fact = try XCTUnwrap(store.claims(of: lighthouse.id).first)
        XCTAssertTrue(store.setPinned(fact.id, true))
        XCTAssertTrue(try XCTUnwrap(store.claim(ref: fact.ref)).pinned)
        XCTAssertTrue(store.forgetClaim(fact.id, source: "user"))
        XCTAssertNil(store.claim(ref: fact.ref))
        XCTAssertEqual(store.claims(of: lighthouse.id).count, 1)
        XCTAssertEqual(store.recentChanges(limit: 1).first?.action, .forgot)
        XCTAssertFalse(store.forgetClaim(fact.id, source: "user"), "a forgotten fact cannot be forgotten again")
        XCTAssertFalse(store.setPinned(fact.id, true))
    }

    func testForgetAPageClearsItsFactsAndLinksAndOthersStay() async throws {
        try seed()
        let lighthouse = try page("Lighthouse"), maya = try page("Maya Chen")
        store.link(from: maya.id, to: lighthouse.id, type: "works_on", source: "chat:a")
        XCTAssertTrue(store.forgetPage(lighthouse.ref, source: "user"))
        XCTAssertTrue(store.claims(of: lighthouse.id).isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.detail(maya.id)).linkGroups.isEmpty)
        XCTAssertEqual(store.claims(of: maya.id).count, 2)
        XCTAssertFalse(store.forgetPage("page_missing", source: "user"))
    }

    // MARK: Helpers

    func testSourcesAndDays() async {
        XCTAssertEqual(MemorySource("chat:3f2a9c1d").label, "Chat")
        XCTAssertEqual(MemorySource("meeting:2026-11-20-1000").target, "2026-11-20-1000")
        XCTAssertEqual(MemorySource("screen").label, "Screen review")
        XCTAssertEqual(MemorySource.chips(["chat:a", "chat:b", "tasks"]).map(\.label), ["Chat", "Task"])
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertEqual(MemoryDay.label(now, now: now), "Today")
        XCTAssertEqual(MemoryDay.label(now.addingTimeInterval(-86_400), now: now), "Yesterday")
        XCTAssertNil(MemoryDay.parse("nope"))
    }
}
