import XCTest
import IronPetKit
@testable import IronPet
@testable import IronPetCore

/// `GET /v1/records/:id`, the route the phone calls for a record id in chat, over a real listener and an in-memory database.
@MainActor
final class RemoteRecordsTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var token = ""

    override func setUp() async throws {
        TestMemory.isolate()
        h = RemoteServerHarness()
        try await h.start()
        let paired = try await h.pairDevice()
        token = paired.token
        h.api.attach(records: RecordRefs(database: h.database))
    }

    override func tearDown() async throws {
        await h.stop()
    }

    /// Task records are gone: the migration deletes their ids, and `task` is no longer a record kind.
    func testATaskIdFromBeforeTheInboxIsNotFound() async throws {
        let reply = try await h.request("GET", "/v1/records/task_9f3c1e", token: token)
        XCTAssertEqual(reply.status, 404)
        XCTAssertEqual((reply.json["error"] as? [String: Any])?["code"] as? String, "not_found")
    }

    func testAnIdThatNamesNothingIsNotFound() async throws {
        let reply = try await h.request("GET", "/v1/records/task_000000", token: token)
        XCTAssertEqual(reply.status, 404)
        XCTAssertEqual((reply.json["error"] as? [String: Any])?["code"] as? String, "not_found")
    }

    func testTheRouteNeedsADevice() async throws {
        let reply = try await h.request("GET", "/v1/records/task_000000")
        XCTAssertEqual(reply.status, 401)
    }
}
