import IronPetKit
import UIKit
import XCTest
@testable import IronPetRemote

/// Step 4 of #190: a screenshot the Mac holds shows on the phone as a thumbnail and opens full size, fetched by message id.
@MainActor
final class ChatImagesTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func client(token: String? = nil) -> IronPetClient {
        IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: token ?? server.token)
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testAScreenshotComesBackAsAThumbnailAndAsTheFullPicture() async throws {
        server.setChatImage(png(width: 2000, height: 1200), for: "shot-1")
        let images = ChatImages(client: client())
        let thumbnail = try await images.thumbnail(for: "shot-1").get()
        XCTAssertLessThanOrEqual(max(thumbnail.cgImage!.width, thumbnail.cgImage!.height), ChatImages.thumbnailPixels, "a thumbnail is not decoded at full size")
        XCTAssertEqual(thumbnail.cgImage!.width, ChatImages.thumbnailPixels)
        let full = try await images.full(for: "shot-1").get()
        XCTAssertEqual(full.cgImage!.width, 2000, "the full picture keeps its size")
    }

    func testTheMacIsAskedOnceNoMatterHowManyRowsAndTapsUseTheImage() async throws {
        server.setChatImage(png(width: 400, height: 300), for: "shot-1")
        let images = ChatImages(client: client())
        async let a = images.thumbnail(for: "shot-1")
        async let b = images.thumbnail(for: "shot-1")
        _ = await (a, b)
        _ = await images.full(for: "shot-1")
        _ = await images.thumbnail(for: "shot-1")
        XCTAssertEqual(server.chatImageRequests, 1)
    }

    func testAChatFullOfScreenshotsAsksForThreeAtATime() async {
        let gate = DownloadGate()
        let images = ChatImages(fetch: { id in await gate.run(id) })
        let tasks = (0..<10).map { index in Task { await images.data(for: "m-\(index)") } }
        for _ in 0..<50 { await Task.yield() }
        let peak = await gate.peak
        for task in tasks { _ = await task.value }
        let finished = await gate.finished
        XCTAssertEqual(peak, ChatImages.maxDownloads)
        XCTAssertEqual(finished, 10, "every request still gets its turn")
    }

    func testAnImageTheMacNoLongerHasGivesItsReasonAndNothingToDraw() async {
        let images = ChatImages(client: client())
        let result = await images.thumbnail(for: "gone")
        XCTAssertEqual(result.failureMessage, "the file is no longer on the Mac")
        if case .failure(.refused) = result {} else { XCTFail("the Mac refused, so the failure says so") }
    }

    func testAnUnpairedPhoneGetsNoBytes() async {
        server.setChatImage(png(width: 40, height: 40), for: "shot-1")
        server.tokenValid = false
        let result = await ChatImages(client: client()).thumbnail(for: "shot-1")
        XCTAssertNil(result.image, "a revoked token reads nothing")
        XCTAssertNotNil(result.failureMessage)
    }

    func testBytesThatAreNotAPictureAreAFailureNotACrash() async {
        server.setChatImage(Data("not a picture".utf8), for: "shot-1")
        let result = await ChatImages(client: client()).thumbnail(for: "shot-1")
        XCTAssertEqual(result.failureMessage, "The phone could not read this image.")
    }

    func testAMessageListedByTheMacShowsItsImageInTheTranscriptModel() async throws {
        server.setChatImage(png(width: 600, height: 400), for: "m-shot")
        let events = SharedEventSource(EventConnection(client: client(), backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client(), events: events, onUnauthorized: {})
        let image = try await model.images.thumbnail(for: "m-shot").get()
        XCTAssertGreaterThan(image.size.width, 0)
    }
}

private extension Result where Success == UIImage, Failure == ChatImages.Failure {
    var image: UIImage? { if case .success(let value) = self { return value } else { return nil } }
    var failureMessage: String? { if case .failure(let error) = self { return error.message } else { return nil } }
}

/// Counts how many downloads run at once.
private actor DownloadGate {
    private(set) var peak = 0
    private(set) var finished = 0
    private var running = 0

    func run(_ id: String) async -> Data {
        running += 1; peak = max(peak, running)
        try? await Task.sleep(for: .milliseconds(30))
        running -= 1; finished += 1
        return Data(id.utf8)
    }
}
