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

    private func makeTask() throws -> String {
        try h.api.tasks.create(CreateTaskRequest(title: "Review the contract", notes: "", status: .needsYou, source: .user, due: nil, links: [],
                                                 waitingOn: nil, sourceRef: nil, labels: [:], by: "test")).id
    }

    func testATaskIdOpensItsTask() async throws {
        let key = try makeTask()
        let ref = try XCTUnwrap(RecordRefs(database: h.database).ref(.task, key))
        let reply = try await h.request("GET", "/v1/records/\(ref)", token: token)
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.json["kind"] as? String, "task")
        XCTAssertEqual(reply.json["ref"] as? String, ref)
        XCTAssertEqual(reply.json["key"] as? String, key)
        XCTAssertEqual(reply.json["title"] as? String, "Review the contract", "the task's fields sit beside its ids, as the phone's task detail has them")
    }

    func testAnOldTaskIdAnswersWithTheSameRecord() async throws {
        let key = try makeTask()
        let ref = try XCTUnwrap(RecordRefs(database: h.database).ref(.task, key))
        let reply = try await h.request("GET", "/v1/records/\(key)", token: token)
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.json["ref"] as? String, ref, "the old id resolves to the same public id")
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
