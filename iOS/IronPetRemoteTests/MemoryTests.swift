import IronPetKit
import XCTest
@testable import IronPetRemote

/// The phone's Memory model against the mock Mac, which serves invented pages.
@MainActor
final class MemoryTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() async throws { server.stop() }

    private func model() -> MemoryModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        return MemoryModel(client: client, events: events, onUnauthorized: {})
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(30)
        while Date() < end, !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testTheListLoadsAndAChipAndSearchNarrowIt() async throws {
        let model = model()
        model.start()
        await waitUntil { model.loaded }
        XCTAssertEqual(model.list?.pages.map(\.name), ["Lighthouse", "Maya Chen", "Linear"])
        await model.select(.people)
        XCTAssertEqual(model.list?.pages.map(\.name), ["Maya Chen"])
        await model.select(.people)
        XCTAssertEqual(model.filter, .all, "the selected chip again returns to All")
        model.query = "maya"
        await model.reload()
        XCTAssertEqual(model.list?.countLabel, "1 of 3 pages")
        model.stop()
    }

    func testAPageLoadsAndALinkLoadsTheLinkedPage() async throws {
        let model = model()
        await model.loadPage("page_4e91b0")
        let page = try XCTUnwrap(model.pages["page_4e91b0"])
        XCTAssertEqual(page.facts.first?.pinned, true)
        let link = try XCTUnwrap(page.linkGroups.first?.links.first)
        await model.loadPage(link.id)
        XCTAssertEqual(model.pages[link.id]?.title, "Maya Chen")
    }

    func testPinForgetFactAndForgetPageUpdateTheMacAndTheModel() async throws {
        let model = model()
        await model.reload()
        await model.loadPage("page_4e91b0")
        let second = try XCTUnwrap(model.pages["page_4e91b0"]?.facts.last)
        await model.pin(second, on: "page_4e91b0")
        XCTAssertEqual(server.memoryPages[0].facts.first { $0.id == second.id }?.pinned, true)
        await model.forget(second, on: "page_4e91b0")
        XCTAssertEqual(model.pages["page_4e91b0"]?.facts.count, 1)
        await model.forgetPage("page_7c11d2")
        XCTAssertTrue(model.forgottenPages.contains("page_7c11d2"))
        XCTAssertEqual(model.list?.pages.map(\.id), ["page_4e91b0", "page_9594cc"])
    }

    func testTheBrainIconComesFromTheSharedTable() {
        XCTAssertEqual(SharedSymbols.memory, "brain")
        XCTAssertEqual(MoreDestination.memoryPage("page_1"), MoreDestination.memoryPage("page_1"))
    }
}
