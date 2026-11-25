import XCTest
@testable import IronPetKit

/// The Memory client calls and models against the mock Mac, which serves invented pages.
final class MemoryClientTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func client() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    func testTheListDecodesAndTheChipAndSearchGoInTheQuery() async throws {
        let all = try await client().memory()
        XCTAssertEqual(all.pages.map(\.name), ["Lighthouse", "Maya Chen", "Linear"])
        XCTAssertEqual(all.countLabel, "3 pages")
        XCTAssertEqual(all.pages[0].summary, "Database migrations are one-way.", "the pinned fact is the summary")
        let people = try await client().memory(filter: .people, query: "maya")
        XCTAssertEqual(people.pages.map(\.name), ["Maya Chen"])
        XCTAssertEqual(people.countLabel, "1 of 1 people")
        let sent = try XCTUnwrap(server.requests.last { $0.line.hasPrefix("GET /v1/memory") })
        XCTAssertTrue(sent.query.contains("filter=people") && sent.query.contains("q=maya"))
    }

    func testAPageDecodesAndFollowingALinkReadsTheNextPage() async throws {
        let page = try await client().memoryPage(id: "page_4e91b0")
        XCTAssertEqual(page.title, "Lighthouse")
        XCTAssertEqual(page.facts.first?.pinned, true)
        XCTAssertEqual(page.earlier.count, 1)
        let link = try XCTUnwrap(page.linkGroups.first?.links.first)
        XCTAssertEqual(page.linkGroups.first?.title, "Worked on by")
        let next = try await client().memoryPage(id: link.id)
        XCTAssertEqual(next.title, "Maya Chen")
        do { _ = try await client().memoryPage(id: "page_nope"); XCTFail("found a missing page") } catch ClientError.api(let status, _, _) {
            XCTAssertEqual(status, 404)
        }
    }

    func testPinAndForgetReachTheMac() async throws {
        try await client().pinMemoryFact(id: "claim_a1", pinned: false)
        try await client().pinMemoryFact(id: "claim_a2", pinned: true)
        XCTAssertEqual(server.memoryPages[0].facts.first?.id, "claim_a2", "pinned facts sort first")
        try await client().forgetMemoryFact(id: "claim_a1")
        XCTAssertEqual(server.memoryPages[0].facts.map(\.id), ["claim_a2"])
        try await client().forgetMemoryPage(id: "page_7c11d2")
        XCTAssertEqual(server.memoryPages.map(\.id), ["page_4e91b0", "page_9594cc"])
    }

    func testSourcesAndDaysReadTheSameOnThePhone() {
        XCTAssertEqual(MemorySource.chips(["chat:abc", "screen"]).map(\.label), ["Chat", "Screen review"])
        XCTAssertEqual(MemorySource("meeting:2026-11-20-1000").kind, .meeting)
        XCTAssertEqual(RemoteMemoryFilter.allCases.map(\.title), ["All", "People", "Projects", "Organizations", "Topics", "Tools"])
    }
}
