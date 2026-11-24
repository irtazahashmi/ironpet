import XCTest
@testable import IronPetCore

/// Matching a name to an entity: an identifier first, then a name or alias of the same type, and never a guess between two.
final class EntityMatcherTests: XCTestCase {
    private let ana = EntityRecord(id: "person:ana", type: .person, name: "Ana Silva", aliases: ["Ana"])
    private let project = EntityRecord(id: "project:github.com/you/ana", type: .project, name: "ana", identifiers: ["github.com/you/ana"])

    func testANameOrAliasOfTheSameTypeFinds() {
        XCTAssertEqual(EntityMatcher.match(name: "ana", type: .person, in: [ana, project]), .found("person:ana"))
        XCTAssertEqual(EntityMatcher.match(name: "Ana Silva", type: .person, in: [ana]), .found("person:ana"))
    }

    func testTheTypeDecidesWhichEntityAnameMeans() {
        XCTAssertEqual(EntityMatcher.match(name: "Ana", type: .project, in: [ana, project]), .found("project:github.com/you/ana"))
        XCTAssertEqual(EntityMatcher.match(name: "Ana", in: [ana, project]), .ambiguous(["person:ana", "project:github.com/you/ana"]),
                       "without a type the matcher asks rather than picks")
    }

    func testAnIdentifierBeatsTheName() {
        let other = EntityRecord(id: "project:other", type: .project, name: "demo")
        let repo = EntityRecord(id: "project:github.com/you/demo", type: .project, name: "demo-app", identifiers: ["github.com/you/demo"])
        XCTAssertEqual(EntityMatcher.match(name: "demo", identifiers: ["github.com/you/demo"], type: .project, in: [other, repo]),
                       .found("project:github.com/you/demo"))
    }

    func testTwoEntitiesWithTheSameNameAreAmbiguous() {
        let second = EntityRecord(id: "person:ana-2", type: .person, name: "Ana", aliases: [])
        XCTAssertEqual(EntityMatcher.match(name: "Ana", type: .person, in: [ana, second]), .ambiguous(["person:ana", "person:ana-2"]))
    }

    func testAnUnknownOrEmptyNameMatchesNothing() {
        XCTAssertEqual(EntityMatcher.match(name: "Bo", type: .person, in: [ana]), .none)
        XCTAssertEqual(EntityMatcher.match(name: "   ", type: .person, in: [ana]), .none)
    }

    func testPersonIdsIgnoreCaseAndSpacing() {
        XCTAssertEqual(EntityMatcher.personID("Ana "), EntityMatcher.personID("ana"))
        XCTAssertEqual(EntityMatcher.personID("Ana"), "person:ana")
    }
}
