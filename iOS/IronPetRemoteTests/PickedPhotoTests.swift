import CoreGraphics
import ImageIO
import IronPetKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import IronPetRemote

/// Photos from the picker: HEIC and oversize originals are converted, a photo that fails to load is reported, and a failed upload
/// leaves a Retry that sends the message once. Against the mock server.
@MainActor
final class PickedPhotoTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() async throws { server.stop() }

    private func started() async -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.start()
        await wait { model.loaded && model.snapshot != nil }
        return model
    }

    private func wait(_ timeout: Double = 30, _ condition: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func picture(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator), blue: .random(in: 0...1, using: &generator), alpha: 1)
            context.fill(CGRect(x: .random(in: 0..<Double(width), using: &generator), y: .random(in: 0..<Double(height), using: &generator), width: Double(width) / 7, height: Double(height) / 7))
        }
        return context.makeImage()!
    }

    private func encoded(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func load(_ data: Data) -> @Sendable () async throws -> Data? { { data } }

    // S2
    func testAHEICPhotoIsAttachedAsJPEG() async throws {
        let heic = try XCTUnwrap(encoded(picture(width: 1600, height: 1200), as: .heic), "this simulator cannot encode HEIC for the fixture")
        let model = await started()
        await model.attachPhotos([load(heic)])
        let attachment = try XCTUnwrap(model.attachments.first)
        XCTAssertEqual(attachment.contentType, "image/jpeg")
        XCTAssertTrue(attachment.fileName.hasSuffix(".jpg"))
        model.draft = "heic"
        await model.send()
        let upload = try XCTUnwrap(server.requests.first { $0.path == "/v1/uploads" })
        XCTAssertEqual(upload.headers["content-type"], "image/jpeg")
        XCTAssertEqual(Array(upload.body.prefix(2)), [0xFF, 0xD8], "the uploaded bytes are a JPEG")
        model.stop()
    }

    // S3
    func testAPhotoOver20MBIsShrunkUnderTheLimitAndSent() async throws {
        let tiff = try XCTUnwrap(encoded(picture(width: 3200, height: 2400), as: .tiff))
        XCTAssertGreaterThan(tiff.count, ChatModel.maxUploadBytes, "the fixture is over the Mac's limit")
        let model = await started()
        await model.attachPhotos([load(tiff)])
        let attachment = try XCTUnwrap(model.attachments.first)
        XCTAssertEqual(attachment.contentType, "image/jpeg")
        XCTAssertLessThanOrEqual(attachment.data.count, PastedImage.maxBytes)
        await model.send()
        XCTAssertEqual(server.count("POST /v1/uploads"), 1)
        XCTAssertEqual(server.count("POST /v1/chat/current/messages"), 1)
        model.stop()
    }

    // S5
    func testAPastedImageAndSeveralPhotosAllArrive() async throws {
        let png = try XCTUnwrap(encoded(picture(width: 600, height: 400), as: .png))
        let jpeg = try XCTUnwrap(encoded(picture(width: 900, height: 600), as: .jpeg))
        let heic = try XCTUnwrap(encoded(picture(width: 800, height: 800), as: .heic))
        let model = await started()
        await model.attachPastedImage(png)
        await model.attachPhotos([load(jpeg), load(heic)])
        XCTAssertEqual(model.attachments.count, 3)
        XCTAssertEqual(Set(model.attachments.map(\.fileName)).count, 3, "each has its own name")
        await model.send()
        XCTAssertEqual(server.count("POST /v1/uploads"), 3)
        let send = try XCTUnwrap(server.requests.last { $0.path == "/v1/chat/current/messages" })
        XCTAssertEqual((send.json["upload_ids"] as? [String])?.count, 3)
        model.stop()
    }

    func testAPhotoThatCannotLoadIsReportedAndTheOthersStillAttach() async throws {
        let jpeg = try XCTUnwrap(encoded(picture(width: 900, height: 600), as: .jpeg))
        struct Gone: Error {}
        let model = await started()
        await model.attachPhotos([{ throw Gone() }, load(jpeg), { nil }])
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertEqual(model.errorMessage, "2 photos could not be loaded. Try picking them again.")
        model.stop()
    }

    // S4
    func testAFailedUploadShowsItsReasonAndRetrySendsTheMessageOnce() async throws {
        let jpeg = try XCTUnwrap(encoded(picture(width: 900, height: 600), as: .jpeg))
        let model = await started()
        await model.attachPhotos([load(jpeg)])
        model.draft = "look"
        server.uploadFails = true
        await model.send()
        XCTAssertNotNil(model.uploadFailure, "the composer has a reason to show next to Retry")
        XCTAssertEqual(model.attachments.count, 1, "the photo is still attached")
        XCTAssertEqual(model.draft, "look")
        XCTAssertEqual(server.count("POST /v1/chat/current/messages"), 0)
        server.uploadFails = false
        await model.send()
        XCTAssertNil(model.uploadFailure)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertEqual(server.count("POST /v1/chat/current/messages"), 1, "one message after the retry")
        model.stop()
    }
}
