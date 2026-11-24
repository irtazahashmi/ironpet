import XCTest
import IronPetKit
@testable import IronPetRemote

/// A screen that never loaded shows the full-page error. One that loaded once keeps its data and shows nothing of its own.
@MainActor
final class LoadErrorTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func model(_ network: NetworkHealth) -> AgentsModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        network.retryPolicy = RetryPolicy(attempts: 2, base: .milliseconds(10))
        return AgentsModel(client: client, events: SharedEventSource(EventConnection(client: client)), network: network, onUnauthorized: {})
    }

    // S4
    func testAScreenThatNeverLoadedShowsTheFullPageError() async {
        let network = NetworkHealth()
        let agents = model(network)
        server.stop()
        await agents.refresh()
        XCTAssertTrue(agents.showsLoadError)
        XCTAssertFalse(agents.loaded, "no empty state either")
        XCTAssertNil(agents.errorMessage)
    }

    // S4
    func testRetryLoadsTheScreenAndTheErrorGoes() async throws {
        let network = NetworkHealth()
        let agents = model(network)
        server.stop()
        await agents.refresh()
        XCTAssertTrue(agents.showsLoadError)
        try server.start()
        await agents.refresh()
        XCTAssertFalse(agents.showsLoadError)
        XCTAssertTrue(agents.loaded)
    }

    // S1
    func testAScreenThatLoadedKeepsItsDataWhenTheMacGoesAway() async {
        let network = NetworkHealth()
        let agents = model(network)
        await agents.refresh()
        let before = agents.agents
        XCTAssertFalse(before.isEmpty)
        server.stop()
        await agents.refresh()
        XCTAssertFalse(agents.showsLoadError, "it loaded once, so no full-page error")
        XCTAssertEqual(agents.agents, before, "the last data stays")
        XCTAssertNil(agents.errorMessage)
        XCTAssertNotNil(network.failingSince)
    }

    func testAMacThatDoesNotKnowThePetRouteRaisesTheOneTimeSheet() async {
        let network = NetworkHealth()
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let pet = PetModel(client: client, events: SharedEventSource(EventConnection(client: client)), cache: AssetCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                           network: network, onUnauthorized: {})
        server.brokenRoutes = ["/v1/pet": 404]
        await pet.reloadPet(applyMood: false)
        XCTAssertEqual(network.problem, .macTooOld)
        XCTAssertNil(network.failingSince, "the Mac answered, so the strip stays away")
    }
}
