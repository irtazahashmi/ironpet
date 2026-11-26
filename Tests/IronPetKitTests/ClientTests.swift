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

    // S8 (client): the cursor of the last answer goes out as `after` and `epoch`, and the answer's cursor and delta flag decode.
    func testAChatReadSendsTheCursorAndDecodesTheDelta() async throws {
        server.chat.items = [RemoteChatItem(id: "a", kind: "user", text: "one")]
        _ = try await paired().chatIfChanged(etag: nil, limit: 50, after: 41, epoch: "launch-1")
        let request = try XCTUnwrap(server.requests.last { $0.path == "/v1/chat/current" })
        XCTAssertTrue(request.query.contains("after=41"))
        XCTAssertTrue(request.query.contains("epoch=launch-1"))
        let page = try JSONDecoder().decode(RemoteChatSnapshot.self, from: Data(#"{"title":"t","state":"idle","running":false,"folder_label":"f","agent":{"id":"claude","name":"Claude"},"items":[],"approvals":[],"forms":[],"queue":[],"options":{},"epoch":"e","seq":9,"delta":true}"#.utf8))
        XCTAssertEqual(page.seq, 9)
        XCTAssertEqual(page.epoch, "e")
        XCTAssertEqual(page.delta, true)
    }

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

    func testListsTheInboxWithTheToken() async throws {
        let items = try await paired().suggestions()
        XCTAssertEqual(items.count, MockIronPetServer.sampleSuggestions.count)
        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.headers["authorization"], "Bearer \(server.token)")
        XCTAssertEqual(request.line, "GET /v1/suggestions")
    }

    func testUnauthorizedWithAToken() async throws {
        server.tokenValid = false
        do { _ = try await paired().suggestions(); XCTFail("expected 401") } catch { XCTAssertEqual(error as? ClientError, .unauthorized) }
    }

    func testDoneAndRemove() async throws {
        let client = paired()
        try await client.acceptSuggestion(id: "s-1")
        try await client.rejectSuggestion(id: "s-2")
        XCTAssertEqual(server.requests.map(\.line), ["POST /v1/suggestions/s-1/accept", "POST /v1/suggestions/s-2/reject"])
        XCTAssertEqual(server.suggestions.count, MockIronPetServer.sampleSuggestions.count - 2)
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
        do { try await paired().acceptSuggestion(id: "gone"); XCTFail("expected 404") } catch {
            XCTAssertEqual(error as? ClientError, .api(status: 404, code: "not_found", message: "no suggestion gone"))
        }
    }

    func testInboxIdIsPercentEncodedExactlyOnce() async throws {
        let client = paired()
        let request = client.request("POST", APIPath.acceptSuggestion("ask-süd-nord"))
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/v1/suggestions/ask-s%C3%BCd-nord/accept"), request.url!.absoluteString)
        let percent = client.request("POST", APIPath.rejectSuggestion("50%-done"))
        XCTAssertTrue(percent.url!.absoluteString.hasSuffix("/v1/suggestions/50%25-done/reject"), percent.url!.absoluteString)
    }
}
