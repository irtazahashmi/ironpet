import XCTest
@testable import IronPet
@testable import IronPetCore

/// The two routes the phone agent uses: the inbox add that its queue delivers to, and its registration as an agent of the node.
@MainActor
final class PhoneAgentRouteTests: XCTestCase {
    func testTheMacAddsAnItemFromThePhoneOnceHoweverOftenItIsSent() throws {
        let api = APITestSupport.makeAPI()
        let route = RemoteTasks(api: api)
        let body: [String: Any] = ["id": "phone-123", "title": "Call Tom", "due": "2026-11-27", "notes": "about the contract"]
        let first = try route.add(body, device: "dev_1")
        XCTAssertEqual(first["added"] as? Bool, true)
        XCTAssertEqual(api.tasks.suggestions.map(\.title), ["Call Tom"])
        XCTAssertEqual(api.tasks.suggestions.first?.due, "2026-11-27")
        XCTAssertEqual(first["id"] as? String, api.tasks.suggestions.first?.id)
        let again = try route.add(body, device: "dev_1")
        XCTAssertEqual(again["added"] as? Bool, false)
        XCTAssertEqual(api.tasks.suggestions.count, 1)
        // The user removes it. A late resend of the same id does not bring it back.
        try api.tasks.remove(RemoveSuggestionRequest(id: try XCTUnwrap(api.tasks.suggestions.first?.id)))
        XCTAssertEqual(try route.add(body, device: "dev_1")["added"] as? Bool, false)
        XCTAssertTrue(api.tasks.suggestions.isEmpty)
    }

    func testTheMacRefusesAnItemWithoutATitleOrAnId() throws {
        let route = RemoteTasks(api: APITestSupport.makeAPI())
        XCTAssertThrowsError(try route.add(["id": "phone-1"], device: "dev_1")) { XCTAssertEqual(($0 as? RemoteFailure)?.status, 400) }
        XCTAssertThrowsError(try route.add(["title": "x"], device: "dev_1")) { XCTAssertEqual(($0 as? RemoteFailure)?.status, 400) }
    }

    func testTheItemRecordsThatTheIphoneAgentMadeIt() throws {
        let api = APITestSupport.makeAPI()
        _ = try RemoteTasks(api: api).add(["id": "phone-1", "title": "Call Tom"], device: "dev_1")
        let ref = try XCTUnwrap(api.tasks.suggestions.first?.sourceRef)
        XCTAssertTrue(ref.contains("iphone:dev_1"), ref)
    }

    func testThePhoneRegistersAsAnAgentOfTheNodeThroughTheMac() throws {
        let registry = AgentRegistry(database: APITestSupport.memoryDatabase())
        let api = APITestSupport.makeAPI(agents: registry)
        let answer = try RemoteResources(api: api, device: "dev_1").registerPhoneAgent(["name": "Ghost on iPhone", "provider": "anthropic", "model": "claude-sonnet-5-5"])
        XCTAssertEqual(answer["device_id"] as? String, "dev_1")
        XCTAssertEqual(registry.list().filter(\.isRemote).map(\.name), ["Ghost on iPhone"])
        let listed = try RemoteResources(api: api, device: "dev_1").agentRecords()
        XCTAssertEqual((listed["agents"] as? [[String: Any]])?.count, 2, "the agents list the phone reads has agent 1 and the phone's agent")
        XCTAssertThrowsError(try RemoteResources(api: api, device: "dev_1").registerPhoneAgent(["name": "x", "provider": "gemini"]))
    }
}
