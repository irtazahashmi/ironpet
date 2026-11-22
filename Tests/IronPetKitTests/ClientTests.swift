import XCTest
@testable import IronPetKit

final class ClientTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    func paired() -> IronPetClient { IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) }

    // MARK: Pairing

    func testPairsAfterAllow() async throws {
        let link = try PairingLink(parsing: server.pairingLink)
        let waiting = expectation(description: "waiting")
        let device = try await PairingFlow(link: link, deviceName: "Test phone", pollInterval: .milliseconds(10)).run { waiting.fulfill() }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertEqual(device.token, server.token)
        XCTAssertEqual(device.deviceID, server.deviceID)
        XCTAssertEqual(server.requests.first?.json["device_name"] as? String, "Test phone")
        XCTAssertEqual(server.requests.first?.json["code"] as? String, server.code)
        XCTAssertEqual(server.count("GET /v1/pair/pairing-1"), 2, "one pending poll, then allowed")
    }

    func testDenied() async throws {
        server.outcome = .deny
        let flow = PairingFlow(link: try PairingLink(parsing: server.pairingLink), deviceName: "Phone", pollInterval: .milliseconds(10))
        do { _ = try await flow.run(); XCTFail("expected a denial") } catch { XCTAssertEqual(error as? ClientError, .pairingDenied) }
    }

    func testWrongCodeIsRefused() async throws {
        let flow = PairingFlow(link: try PairingLink(parsing: "ironpet://pair?u=\(server.baseURL.absoluteString)&c=wrong"), deviceName: "Phone")
        do { _ = try await flow.run(); XCTFail("expected a refusal") } catch {
            guard case .api(let status, _, _) = error as? ClientError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 401)
        }
    }

    // MARK: Requests

    func testListsTasksWithTheToken() async throws {
        let tasks = try await paired().tasks()
        XCTAssertEqual(tasks.count, MockIronPetServer.sampleTasks.count)
        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.headers["authorization"], "Bearer \(server.token)")
        XCTAssertEqual(request.query, "include_done=1")
    }

    func testUnauthorizedWithAToken() async throws {
        server.tokenValid = false
        do { _ = try await paired().tasks(); XCTFail("expected 401") } catch { XCTAssertEqual(error as? ClientError, .unauthorized) }
    }

    func testAcceptRejectCloseAndNote() async throws {
        let client = paired()
        _ = try await client.acceptSuggestion(id: "s-1")
        try await client.rejectSuggestion(id: "s-2")
        _ = try await client.closeTask(id: "t-needs", note: "done and checked")
        _ = try await client.addNote(id: "t-backlog", note: "a note")
        _ = try await client.setStatus(id: "t-backlog", status: .inProgress, note: "started")
        XCTAssertEqual(server.requests.map(\.line), ["POST /v1/suggestions/s-1/accept", "POST /v1/suggestions/s-2/reject", "POST /v1/tasks/t-needs/close",
                                                      "PATCH /v1/tasks/t-backlog", "PATCH /v1/tasks/t-backlog"])
        XCTAssertEqual(server.requests[2].json["note"] as? String, "done and checked")
        XCTAssertEqual(server.requests[4].json["status"] as? String, "in_progress")
        XCTAssertEqual(server.requests[4].json["note"] as? String, "started")
    }

    func testSetWaitingOnSendsWaitingOnAndClearsItWithABlankName() async throws {
        let client = paired()
        _ = try await client.setWaitingOn(id: "t-backlog", name: "Ana")
        _ = try await client.setWaitingOn(id: "t-backlog", name: nil, status: .needsYou, note: "back to me")
        XCTAssertEqual(server.requests.map(\.line), ["PATCH /v1/tasks/t-backlog", "PATCH /v1/tasks/t-backlog"])
        XCTAssertEqual(server.requests[0].json["waiting_on"] as? String, "Ana")
        XCTAssertNil(server.requests[0].json["status"], "the status stays when none is given")
        XCTAssertEqual(server.requests[1].json["waiting_on"] as? String, "")
        XCTAssertEqual(server.requests[1].json["status"] as? String, "needs_you")
        XCTAssertEqual(server.requests[1].json["note"] as? String, "back to me")
    }

    // MARK: File previews

    func testFilePreviewReadsTextImagesAndTheTruncationHeader() async throws {
        let client = paired()
        server.setFilePreview(Data("let a = 1\n".utf8), path: "/Users/dev/demo-app/src/a b+c.swift")
        server.setFilePreview(Data("start".utf8), path: "/Users/dev/demo-app/big.log", truncated: true)
        server.setFilePreview(Data([1, 2, 3]), path: "/Users/dev/demo-app/shot.png", contentType: "image/png")

        let text = try await client.filePreview(path: "/Users/dev/demo-app/src/a b+c.swift")
        XCTAssertEqual(text.text, "let a = 1\n")
        XCTAssertFalse(text.truncated)
        XCTAssertEqual(server.previewRequests.last, "/Users/dev/demo-app/src/a b+c.swift", "a space and a plus reach the Mac as typed")
        let big = try await client.filePreview(path: "/Users/dev/demo-app/big.log")
        XCTAssertTrue(big.truncated)
        let image = try await client.filePreview(path: "/Users/dev/demo-app/shot.png")
        XCTAssertTrue(image.isImage)
        XCTAssertEqual(image.data, Data([1, 2, 3]))
    }

    func testFilePreviewThrowsTheMacsReasonForAPathItRefuses() async throws {
        let client = paired()
        do {
            _ = try await client.filePreview(path: "/etc/hosts")
            XCTFail("expected a refusal")
        } catch ClientError.api(let status, let code, let message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(code, "forbidden")
            XCTAssertEqual(message, "the Mac only previews files inside the folders its chat works in")
        }
        do {
            _ = try await client.filePreview(path: "/Users/dev/demo-app/gone.swift")
            XCTFail("expected a 404")
        } catch ClientError.api(let status, _, let message) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(message, "there is no such file on the Mac")
        }
    }

    func testRevokeSelf() async throws {
        try await paired().revokeSelf()
        XCTAssertEqual(server.requests.last?.line, "DELETE /v1/devices/me")
    }

    func testApiErrorKeepsTheMessage() async throws {
        do { _ = try await paired().closeTask(id: "t-needs", note: ""); XCTFail("expected 400") } catch {
            XCTAssertEqual(error as? ClientError, .api(status: 400, code: "invalid", message: "note is required"))
        }
    }

    func testTaskIdIsPercentEncodedExactlyOnce() async throws {
        let client = paired()
        let request = client.request("GET", APIPath.task("ask-süd-nord"))
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/v1/tasks/ask-s%C3%BCd-nord"), request.url!.absoluteString)
        let percent = client.request("GET", APIPath.task("50%-done"))
        XCTAssertTrue(percent.url!.absoluteString.hasSuffix("/v1/tasks/50%25-done"), percent.url!.absoluteString)
    }
}
