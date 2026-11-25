import XCTest
@testable import IronPet
@testable import IronPetCore

/// The Memory section's state: the chip toggle, search, the page stack, Esc, and that pin and forget reach the store and the view.
@MainActor
final class MemorySectionTests: XCTestCase {
    private var store: EntityMemoryStore!
    private var model: MemorySectionModel!

    private var project: ProjectKey {
        ProjectKey(key: "git.example.test/lighthouse", name: "Lighthouse", isRepo: true, workspace: URL(fileURLWithPath: "/tmp/lighthouse"))
    }

    override func setUp() async throws {
        TestMemory.isolate()
        store = EntityMemoryStore(database: APITestSupport.memoryDatabase())
        _ = store.remember("Database migrations are one-way.", scope: .project, project: project, source: "chat:a")
        _ = store.remember("CI size limit is 64 MB.", scope: .project, project: project, source: "screen")
        _ = store.remember("Owns the Lighthouse repository.", scope: .people, person: "Maya Chen", source: "tasks")
        _ = store.remember("Said the booking intent rose.", scope: .people, person: "Maya Cheng", source: "chat:b")
        let lighthouse = try XCTUnwrap(store.entities().first { $0.name == "Lighthouse" })
        let maya = try XCTUnwrap(store.entities().first { $0.name == "Maya Chen" })
        store.link(from: maya.id, to: lighthouse.id, type: "works_on", source: "chat:a")
        let api = MemoryAPI(services: { nil }, pages: { [store] in store! })
        model = MemorySectionModel(api: { api })
        model.reload()
    }

    private func id(_ name: String) throws -> String { try XCTUnwrap(store.entities().first { $0.name == name }).id }

    func testChipAndSearchGiveTheCountAndClickingTheChipAgainReturnsToAll() {
        model.select(.people)
        model.query = "maya"
        model.applyQuery()
        XCTAssertEqual(Set(model.list.rows.map(\.name)), ["Maya Chen", "Maya Cheng"])
        XCTAssertEqual(model.list.countLabel, "2 of 2 people")
        model.select(.people)
        XCTAssertEqual(model.filter, .all)
    }

    func testOpeningALinkGrowsTheTrailAndTheListKeepsItsFilterAndSearch() throws {
        model.select(.projects)
        model.query = "lighthouse"
        model.applyQuery()
        model.open(try id("Lighthouse"))
        model.open(try id("Maya Chen"))
        XCTAssertEqual(model.trail.map(\.title), ["Lighthouse", "Maya Chen"])
        XCTAssertEqual(model.detail?.title, "Maya Chen")
        model.pop(to: 0)
        XCTAssertEqual(model.detail?.title, "Lighthouse")
        model.open(try id("Maya Chen"))
        model.back()
        XCTAssertEqual(model.detail?.title, "Lighthouse")
        model.back()
        XCTAssertFalse(model.nav.isOpen)
        XCTAssertEqual(model.filter, .projects)
        XCTAssertEqual(model.applied, "lighthouse")
    }

    func testEscapeGoesBackThenClearsTheSearchThenDoesNothing() throws {
        model.query = "maya"
        model.applyQuery()
        model.open(try id("Maya Chen"))
        model.escape()
        XCTAssertFalse(model.nav.isOpen)
        XCTAssertEqual(model.applied, "maya", "Esc on a page goes back and keeps the search")
        model.escape()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.applied, "")
        model.escape()
        XCTAssertFalse(model.nav.isOpen)
    }

    func testUpAndDownMoveTheFocusRingAndStopAtTheEnds() {
        let ids = model.list.rows.map(\.id)
        model.moveFocus(1)
        XCTAssertEqual(model.focused, ids.first)
        model.moveFocus(1); model.moveFocus(1); model.moveFocus(1); model.moveFocus(1); model.moveFocus(1)
        XCTAssertEqual(model.focused, ids.last)
        model.moveFocus(-1)
        XCTAssertEqual(model.focused, ids[ids.count - 2])
    }

    func testPinAndForgetUpdateTheStoreAndTheView() throws {
        let lighthouse = try id("Lighthouse")
        model.open(lighthouse)
        let fact = try XCTUnwrap(model.detail?.facts.last)
        model.pin(fact)
        XCTAssertEqual(model.detail?.facts.first?.id, fact.id)
        XCTAssertTrue(model.detail?.facts.first?.pinned ?? false)
        XCTAssertEqual(model.rows.first { $0.id == lighthouse }?.summary, fact.text)
        model.forget(try XCTUnwrap(model.detail?.facts.first))
        XCTAssertEqual(model.detail?.facts.count, 1)
        model.forgetPage(lighthouse)
        XCTAssertNil(model.rows.first { $0.id == lighthouse })
        XCTAssertFalse(model.nav.isOpen, "the forgotten page leaves the trail")
    }

    func testWithNoMemoryTheSectionIsEmptyNotBroken() {
        let none = MemorySectionModel(api: { nil })
        none.reload()
        XCTAssertFalse(none.available)
        XCTAssertTrue(none.rows.isEmpty)
    }
}
