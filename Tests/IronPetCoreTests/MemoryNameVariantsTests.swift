import XCTest
@testable import IronPetCore

/// Spelling and naming variants of one entity find its page, and the duplicate banner offers pages of every type for merging.
@MainActor
final class MemoryNameVariantsTests: XCTestCase {
    private var store: EntityMemoryStore!

    override func setUp() async throws {
        store = EntityMemoryStore(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    private func file(_ text: String, _ scope: MemoryScope, _ name: String) throws {
        if scope == .people {
            try store.remember(text, scope: .people, person: name, source: "chat:a").get()
        } else {
            try store.remember(text, scope: scope, entity: name, source: "chat:a").get()
        }
    }

    private func facts(_ id: String) -> [String] { store.claims(of: id).map(\.text) }

    // MARK: S1

    func testAHyphenatedNameFindsTheSpacedPage() async throws {
        try file("Takes card payments.", .project, "Rabbit Checkout")
        try file("Ships on Fridays.", .project, "rabbit-checkout")
        XCTAssertEqual(store.entities().filter { $0.type == .project }.map(\.name), ["Rabbit Checkout"])
        XCTAssertEqual(facts("project:rabbit checkout").count, 2)
    }

    // MARK: S2

    func testASurnameFindsTheOnlyPersonWithIt() async throws {
        try file("Leads QA.", .people, "Manfred Nowak")
        try file("Prefers email.", .people, "Nowak")
        XCTAssertEqual(store.entities().filter { $0.type == .person }.map(\.name), ["Manfred Nowak"])
        XCTAssertEqual(facts("person:manfred nowak").count, 2)
    }

    func testALoneFirstNameFindsTheOnlyPersonWithIt() async throws {
        try file("Leads QA.", .people, "Manfred Nowak")
        try file("Prefers email.", .people, "Manfred")
        XCTAssertEqual(facts("person:manfred nowak").count, 2)
    }

    // MARK: S3

    func testAnAliasFindsThePage() async throws {
        try file("Handles refunds.", .project, "Self Service Portal")
        try store.database.write { db in try db.execute("UPDATE memory_entities SET aliases = 'SSP' WHERE id = 'project:self service portal'") }
        try file("Runs on Postgres.", .project, "SSP")
        XCTAssertEqual(store.entities().filter { $0.type == .project }.count, 1)
        XCTAssertEqual(facts("project:self service portal").count, 2)
    }

    func testTheAcronymInBracketsFindsThePageBothWays() async throws {
        try file("Handles refunds.", .project, "Self Service Portal (SSP)")
        try file("Runs on Postgres.", .project, "SSP")
        try file("Has a status page.", .project, "Self Service Portal")
        XCTAssertEqual(store.entities().filter { $0.type == .project }.count, 1)
        XCTAssertEqual(facts(try XCTUnwrap(store.entities().first { $0.type == .project }).id).count, 3)
    }

    func testInitialsNeverFindAPerson() async throws {
        try file("Lives in Vienna.", .people, "Manfred Nowak")
        try file("Likes tea.", .people, "MN")
        XCTAssertEqual(store.entities().filter { $0.type == .person }.count, 2)
        XCTAssertEqual(facts("person:manfred nowak"), ["Lives in Vienna."])
    }

    func testInitialsFindThePageOnlyWhenOneFits() async throws {
        try file("Handles refunds.", .project, "Self Service Portal")
        try file("Runs on Postgres.", .project, "SSP")
        XCTAssertEqual(store.entities().filter { $0.type == .project }.count, 1)
        try file("Other.", .project, "Secure Shell Proxy")
        XCTAssertNil(try? store.remember("Ambiguous.", scope: .project, entity: "SSP", source: "chat:a").get())
    }

    func testASmallSpellingDifferenceFindsAProjectButNotAPerson() async throws {
        try file("Takes payments.", .project, "Rabbit Checkout")
        try file("Ships on Fridays.", .project, "Rabit Checkout")
        XCTAssertEqual(store.entities().filter { $0.type == .project }.count, 1)
        try file("Leads QA.", .people, "Maya Chen")
        try file("Writes docs.", .people, "Maya Cheng")
        XCTAssertEqual(store.entities().filter { $0.type == .person }.count, 2)
    }

    func testNamesWithADigitAreNotSpellingVariants() async throws {
        try file("A.", .org, "Org 1")
        try file("B.", .org, "Org 2")
        XCTAssertEqual(store.entities().filter { $0.type == .org }.count, 2)
    }

    func testAVariantOnAnotherTypeFindsThatPageAndKeepsItsType() async throws {
        try file("Takes payments.", .project, "Rabbit Checkout")
        try file("Owned by the web team.", .tool, "rabbit-checkout")
        XCTAssertEqual(store.entities().filter { $0.name.lowercased().contains("rabbit") }.map(\.type), [.project])
        XCTAssertEqual(facts("project:rabbit checkout").count, 2)
    }

    func testTheSameExactNameOnAnotherTypeStaysAnotherPage() async throws {
        try file("Chat app.", .project, "Band")
        try file("Team of six.", .org, "Band")
        XCTAssertEqual(Set(store.entities().filter { $0.name == "Band" }.map(\.type)), [.project, .org])
    }

    // MARK: S4

    func testTwoPagesForTheSameProductOfferEachOtherForMerging() async throws {
        try file("Takes payments.", .project, "Self Service Portal")
        try file("Runs on Postgres.", .project, "Portal")
        try store.database.write { db in try db.execute("UPDATE memory_entities SET aliases = 'SSP' WHERE id = 'project:portal'") }
        let one = try XCTUnwrap(store.detail("project:self service portal"))
        let two = try XCTUnwrap(store.detail("project:portal"))
        XCTAssertEqual(one.possibleDuplicates.map(\.page), ["project:portal"])
        XCTAssertEqual(two.possibleDuplicates.map(\.page), ["project:self service portal"])
    }

    func testTheBannerSkipsPagesWithoutFactsAndOtherTypes() async throws {
        try file("Takes payments.", .project, "Rabbit Checkout")
        try file("Owned by web.", .org, "Rabbit Checkout")
        _ = store.noteMention(EntityMemoryStore.SeenEntity(name: "rabbit-checkout", type: .project), source: "chat:b")
        XCTAssertTrue(try XCTUnwrap(store.detail("project:rabbit checkout")).possibleDuplicates.isEmpty)
    }

    func testTwoOrgsOneSpellingEditApartOfferEachOther() async throws {
        try file("Pays on time.", .org, "Acme Corp")
        try store.database.write { db in
            try db.execute("INSERT INTO memory_entities(id, type, name, aliases, identifiers, mentions, ref) VALUES('org:acme corps', 'org', 'Acme Corps', '', '', 0, 'page_acmecorps1')")
        }
        try file("Net 30.", .org, "Acme Corps")
        XCTAssertEqual(try XCTUnwrap(store.detail("org:acme corp")).possibleDuplicates.map(\.page), ["org:acme corps"])
    }

    // MARK: S5

    func testAFirstNameFittingTwoPeopleFilesOnNeitherPage() async throws {
        try file("Leads QA.", .people, "Ana Silva")
        try file("Owns billing.", .people, "Ana Lopez")
        XCTAssertNil(try? store.remember("Likes tea.", scope: .people, person: "Ana", source: "chat:a").get())
        XCTAssertEqual(facts("person:ana silva").count, 1)
        XCTAssertEqual(facts("person:ana lopez").count, 1)
        XCTAssertEqual(store.entities().filter { $0.type == .person }.count, 2)
    }

    // MARK: S6

    func testTheUsersOwnNameFilesOnMeNotOnAPerson() async throws {
        try store.remember("Lives in Lisbon.", scope: .me, source: "chat:a").get()
        try store.database.write { db in try db.execute("UPDATE memory_entities SET aliases = 'me\nabout me\nAleks Mirko' WHERE id = 'me'") }
        try file("Prefers tea.", .people, "aleks mirko")
        XCTAssertEqual(facts("me").count, 2)
        XCTAssertTrue(store.entities().filter { $0.type == .person }.isEmpty)
        XCTAssertEqual(try store.noteMention(EntityMemoryStore.SeenEntity(name: "Aleks Mirko", type: .person), source: "chat:b").get(), "me")
        XCTAssertTrue(store.entities().filter { $0.type == .person }.isEmpty)
    }
}
