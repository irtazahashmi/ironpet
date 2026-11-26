import XCTest
@testable import IronPetCore

/// Merging pages: the facts and links of the other pages move onto the kept page, their names become aliases, the old pages go, and a
/// failure leaves everything as it was.
@MainActor
final class MemoryMergePagesTests: XCTestCase {
    private var store: EntityMemoryStore!

    override func setUp() async throws {
        store = EntityMemoryStore(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    private func remember(_ type: EntityType, _ name: String, _ text: String) {
        switch type {
        case .person: _ = store.remember(text, scope: .people, person: name, source: "chat:a")
        case .project: _ = store.remember(text, scope: .project, entity: name, source: "chat:a")
        case .org: _ = store.remember(text, scope: .org, entity: name, source: "chat:a")
        case .topic: _ = store.remember(text, scope: .topic, entity: name, source: "chat:a")
        case .tool: _ = store.remember(text, scope: .tool, entity: name, source: "chat:a")
        case .me: XCTFail("no scope files a note under a type of me")
        }
    }

    private func page(_ name: String) throws -> MemoryEntity { try XCTUnwrap(store.entities().first { $0.name == name }) }

    private func fill(_ type: EntityType, _ name: String, facts: Int) {
        for index in 1...facts { remember(type, name, "\(name) fact number \(index)") }
    }

    // MARK: S1, S3

    func testMergeMovesFactsAndLinksKeepsTheAliasAndRemovesThePage() async throws {
        for type in [EntityType.person, .project, .org, .topic, .tool] {
            store = EntityMemoryStore(database: try Database(path: nil, migrations: AppMigrations.all))
            let short = "Irtaza", long = "Irtaza Hashimi"
            fill(type, short, facts: 30)
            fill(type, long, facts: 2)
            let old = try page(short), kept = try page(long)
            store.link(from: old.id, to: "me", type: "works_on", source: "chat:a")
            store.link(from: "me", to: old.id, type: "knows", source: "chat:a")
            store.link(from: kept.id, to: "me", type: "works_on", source: "chat:b")
            store.link(from: old.id, to: kept.id, type: "same_as", source: "chat:a")

            let merge = try XCTUnwrap(try? store.mergePages([short], into: long).get(), "\(type)")

            XCTAssertEqual(merge.facts, 32, "\(type)")
            XCTAssertEqual(store.claims(of: kept.id).count, 32, "\(type)")
            XCTAssertEqual(merge.merged, [.init(name: short, facts: 30, links: 2)], "\(type)")
            XCTAssertNil(store.entities().first { $0.id == old.id }, "\(type): the old page is gone")
            XCTAssertEqual(try page(long).aliases, [short], "\(type)")
            let links = try store.links(long, type: nil).get()
            XCTAssertEqual(Set(links.map(\.type)), ["works_on", "knows"], "\(type): the link between the two pages is dropped")
            XCTAssertTrue(links.allSatisfy { $0.from == kept.id || $0.to == kept.id }, "\(type): links point at the kept page")
            let works = try XCTUnwrap(links.first { $0.type == "works_on" })
            XCTAssertEqual(works.count, 2, "\(type): the same link on both pages counts once for each")
            XCTAssertEqual(Set(works.sources), ["chat:a", "chat:b"], "\(type)")
            remember(type, short, "A new note about \(short)")
            XCTAssertEqual(store.claims(of: kept.id).count, 33, "\(type): a note about the old name lands on the kept page")
            XCTAssertEqual(store.entities().filter { $0.type == type }.count, 1, "\(type): no page came back")
        }
    }

    func testMergedFactsKeepTheirRefDateSourcesPinAndProvenance() async throws {
        fill(.person, "Irtaza", facts: 2)
        remember(.person, "Irtaza Hashimi", "Lives in Berlin")
        let old = try page("Irtaza"), kept = try page("Irtaza Hashimi")
        let moving = try XCTUnwrap(store.claims(of: old.id).first)
        XCTAssertTrue(store.setPinned(moving.id, true))
        try store.database.write {
            try $0.execute("UPDATE memory_claims SET node_id = 'node-a', agent_id = 'agent-a' WHERE id = ?", [moving.id])
        }

        _ = try store.mergePages(["Irtaza"], into: "Irtaza Hashimi").get()

        let after = try XCTUnwrap(store.claims(of: kept.id).first { $0.id == moving.id })
        XCTAssertEqual(after.ref, moving.ref)
        XCTAssertEqual(after.date, moving.date)
        XCTAssertEqual(after.sources, moving.sources)
        XCTAssertTrue(after.pinned)
        let columns = try store.database.read { try $0.rows("SELECT node_id, agent_id FROM memory_claims WHERE id = ?", [moving.id]) }
        XCTAssertEqual(columns.first?[0] as? String, "node-a")
        XCTAssertEqual(columns.first?[1] as? String, "agent-a")
    }

    func testEarlierFactsFollowAndTheSearchIndexUsesTheKeptPage() async throws {
        remember(.person, "Irtaza", "Works at Acme")
        _ = store.forget("Acme", source: "chat:a")
        remember(.person, "Irtaza", "Prefers dark mode")
        remember(.person, "Irtaza Hashimi", "Lives in Berlin")
        let kept = try page("Irtaza Hashimi")

        _ = try store.mergePages(["Irtaza"], into: "Irtaza Hashimi").get()

        XCTAssertEqual(store.history(of: kept.id).map(\.text), ["Works at Acme"])
        XCTAssertEqual(store.index.search("dark mode", limit: 5).first?.title, "Person · Irtaza Hashimi")
    }

    func testSeveralPagesMergeAtOnceAndNamesRefsAndIDsAllWork() async throws {
        fill(.person, "Ana", facts: 1)
        fill(.person, "Ana Silva", facts: 2)
        fill(.person, "Ana S", facts: 3)
        let ana = try page("Ana"), short = try page("Ana S")

        let merge = try store.mergePages([ana.ref, short.id, ana.id], into: "Ana Silva").get()

        XCTAssertEqual(merge.facts, 6)
        XCTAssertEqual(Set(merge.kept.aliases), ["Ana", "Ana S"])
        XCTAssertEqual(store.entities().filter { $0.type == .person }.map(\.name), ["Ana Silva"])
    }

    // MARK: Refusals leave both pages as they were

    func testRefusalsChangeNothing() async throws {
        fill(.person, "Maya", facts: 2)
        fill(.project, "Maya", facts: 2)
        fill(.person, "Maya Chen", facts: 1)
        let before = store.entities()
        let claims = before.map { store.claims(of: $0.id).map(\.id) }

        for refusal in [store.mergePages(["project:maya"], into: "Maya Chen"),
                        store.mergePages([], into: "Maya Chen"),
                        store.mergePages(["me"], into: "Maya Chen"),
                        store.mergePages(["Maya Chen"], into: "me"),
                        store.mergePages(["Nobody"], into: "Maya Chen"),
                        store.mergePages(["Maya Chen"], into: "Nobody")] {
            if case .success = refusal { XCTFail("must refuse") }
        }
        XCTAssertEqual(store.entities(), before)
        XCTAssertEqual(before.map { store.claims(of: $0.id).map(\.id) }, claims)
    }

    func testPagesOfDifferentTypesDoNotMerge() async throws {
        fill(.person, "Maya", facts: 1)
        fill(.project, "Maya", facts: 1)
        let person = try XCTUnwrap(store.entities().first { $0.type == .person && $0.name == "Maya" })
        let project = try XCTUnwrap(store.entities().first { $0.type == .project && $0.name == "Maya" })
        guard case .failure(let failure) = store.mergePages([project.id], into: person.id) else { return XCTFail("must refuse") }
        XCTAssertTrue(failure.message.contains("only pages of one type merge"), failure.message)
        XCTAssertEqual(store.claims(of: person.id).count, 1)
        XCTAssertEqual(store.claims(of: project.id).count, 1)
    }

    func testAFailureInTheMiddleRollsEverythingBack() async throws {
        fill(.person, "Irtaza", facts: 3)
        fill(.person, "Irtaza Hashimi", facts: 2)
        let old = try page("Irtaza"), kept = try page("Irtaza Hashimi")
        store.link(from: old.id, to: "me", type: "works_on", source: "chat:a")
        // A trigger that refuses the last step, deleting the old page, after the facts and links have already moved.
        try store.database.write {
            try $0.execute("CREATE TRIGGER refuse_delete BEFORE DELETE ON memory_entities BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }

        guard case .failure(let failure) = store.mergePages(["Irtaza"], into: "Irtaza Hashimi") else { return XCTFail("must fail") }

        XCTAssertTrue(failure.message.contains("could not merge the pages"), failure.message)
        XCTAssertEqual(store.claims(of: old.id).count, 3)
        XCTAssertEqual(store.claims(of: kept.id).count, 2)
        XCTAssertEqual(try page("Irtaza Hashimi").aliases, [])
        XCTAssertEqual(try store.links("Irtaza", type: nil).get().count, 1, "the link still belongs to the old page")
    }
}
