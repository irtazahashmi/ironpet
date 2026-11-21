import CoreGraphics
import ImageIO
import IronPetKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import IronPetRemote

private func pasteWait(_ timeout: Double = 30, _ condition: @escaping @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// A picture with some texture, so a JPEG of it is not tiny. `alpha` makes the left half transparent.
private func makeImage(width: Int, height: Int, alpha: Bool = false) -> CGImage {
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<400 {
        context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator), blue: .random(in: 0...1, using: &generator), alpha: 1)
        context.fill(CGRect(x: .random(in: 0..<Double(width), using: &generator), y: .random(in: 0..<Double(height), using: &generator),
                            width: Double(width) / 8, height: Double(height) / 8))
    }
    if alpha { context.clear(CGRect(x: 0, y: 0, width: width / 2, height: height)) }
    return context.makeImage()!
}

private func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func properties(_ data: Data) -> [String: Any] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
    return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
}

/// S5: the normaliser.
final class PastedImageTests: XCTestCase {
    private let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.5, kCGImagePropertyGPSLatitudeRef: "N",
                                                                         kCGImagePropertyGPSLongitude: 13.4, kCGImagePropertyGPSLongitudeRef: "E"],
                                        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"]]

    func testALargePhotoBecomesASmallJPEGWithoutLocation() throws {
        let source = encode(makeImage(width: 6000, height: 4000), type: .jpeg, properties: gps)
        XCTAssertNotNil(properties(source)["{GPS}"], "the fixture carries GPS")
        let result = try XCTUnwrap(PastedImage.normalize(data: source))
        XCTAssertEqual(result.contentType, "image/jpeg")
        XCTAssertEqual(result.fileExtension, "jpg")
        XCTAssertLessThanOrEqual(max(result.width, result.height), 2048)
        XCTAssertEqual(result.width, 2048, "the 3:2 picture keeps its ratio")
        XCTAssertEqual(result.height, 1365, accuracy: 1)
        XCTAssertLessThan(result.data.count, 2_000_000)
        let out = properties(result.data)
        XCTAssertNil(out["{GPS}"])
        XCTAssertNil((out["{Exif}"] as? [String: Any])?["UserComment"])
        XCTAssertEqual(out["PixelWidth"] as? Int, result.width)
    }

    func testALargeOpaquePNGScreenshotBecomesJPEG() throws {
        let source = encode(makeImage(width: 3000, height: 2000), type: .png)
        let result = try XCTUnwrap(PastedImage.normalize(data: source))
        XCTAssertEqual(result.contentType, "image/jpeg")
        XCTAssertLessThanOrEqual(max(result.width, result.height), 2048)
        XCTAssertLessThan(result.data.count, 2_000_000)
    }

    func testAPictureWithTransparencyStaysAPNG() throws {
        let source = encode(makeImage(width: 800, height: 600, alpha: true), type: .png)
        let result = try XCTUnwrap(PastedImage.normalize(data: source))
        XCTAssertEqual(result.contentType, "image/png")
        XCTAssertEqual(result.fileExtension, "png")
        XCTAssertEqual(CGImageSourceGetType(CGImageSourceCreateWithData(result.data as CFData, nil)!) as String?, UTType.png.identifier)
    }

    func testASmallPictureIsNotEnlarged() throws {
        let result = try XCTUnwrap(PastedImage.normalize(data: encode(makeImage(width: 300, height: 200), type: .png)))
        XCTAssertEqual(result.width, 300)
        XCTAssertEqual(result.height, 200)
    }

    func testTheOrientationTagIsAppliedToThePixels() throws {
        // Orientation 6 means "rotate 90 degrees clockwise to display", so a stored 300x100 picture shows as 100x300.
        let source = encode(makeImage(width: 300, height: 100), type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let result = try XCTUnwrap(PastedImage.normalize(data: source))
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 300)
        XCTAssertNil(properties(result.data)["Orientation"], "the output needs no orientation tag")
    }

    func testBytesThatAreNotAnImageAreRefused() {
        XCTAssertNil(PastedImage.normalize(data: Data("not an image".utf8)))
    }

    func testAThumbnailIsSmall() throws {
        let data = try XCTUnwrap(PastedImage.normalize(data: encode(makeImage(width: 2000, height: 1000), type: .png))?.data)
        let thumbnail = try XCTUnwrap(PastedImage.thumbnail(from: data))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width * thumbnail.scale, thumbnail.size.height * thumbnail.scale), 160)
    }
}

/// S2 and S3: what a paste does with what the clipboard holds.
@MainActor
final class ComposerPasteTests: XCTestCase {
    private var board: UIPasteboard!

    override func setUp() async throws {
        board = UIPasteboard(name: UIPasteboard.Name(rawValue: "ironpet-tests-\(UUID().uuidString)"), create: true)
    }

    override func tearDown() async throws { UIPasteboard.remove(withName: board.name) }

    func testTheDecision() {
        XCTAssertEqual(ComposerPaste.decide(hasImage: false, hasText: true), .init(attachImage: false, insertText: true))
        XCTAssertEqual(ComposerPaste.decide(hasImage: true, hasText: false), .init(attachImage: true, insertText: false))
        XCTAssertEqual(ComposerPaste.decide(hasImage: true, hasText: true), .init(attachImage: true, insertText: true), "Safari's picture and its address: both")
        XCTAssertEqual(ComposerPaste.decide(hasImage: false, hasText: false), .init(attachImage: false, insertText: true))
    }

    func testPlainTextAttachesNothing() {
        board.string = "hello"
        var attached: [Data] = []
        XCTAssertTrue(ComposerPaste.handle(board) { attached.append($0) })
        XCTAssertTrue(attached.isEmpty)
    }

    func testAnImageIsHandedOverAndTheTextFieldPastesNothing() throws {
        let png = encode(makeImage(width: 40, height: 30), type: .png)
        board.setData(png, forPasteboardType: UTType.png.identifier)
        var attached: [Data] = []
        XCTAssertFalse(ComposerPaste.handle(board) { attached.append($0) })
        XCTAssertEqual(attached.count, 1)
        XCTAssertNotNil(PastedImage.normalize(data: try XCTUnwrap(attached.first)))
    }

    func testAnImageWithTextAttachesAndAlsoPastesTheText() {
        board.items = [[UTType.png.identifier: encode(makeImage(width: 40, height: 30), type: .png), UTType.utf8PlainText.identifier: "https://example.com/cat.png"]]
        var attached: [Data] = []
        XCTAssertTrue(ComposerPaste.handle(board) { attached.append($0) })
        XCTAssertEqual(attached.count, 1)
    }

    func testAUIImageOnTheClipboardIsRead() throws {
        board.image = UIImage(cgImage: makeImage(width: 40, height: 30))
        var attached: [Data] = []
        ComposerPaste.handle(board) { attached.append($0) }
        XCTAssertEqual(attached.count, 1)
    }
}

/// S4, S6, S12 and S13 on the chat model.
@MainActor
final class PastedAttachmentModelTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func started() async -> ChatModel {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.start()
        await pasteWait { model.loaded && model.snapshot != nil }
        return model
    }

    private func photo(_ width: Int = 600, _ height: Int = 400) -> Data { encode(makeImage(width: width, height: height), type: .png) }

    func testAPastedImageBecomesAJPEGAttachmentWithAThumbnail() async throws {
        let model = await started()
        let added = await model.attachPastedImage(photo())
        XCTAssertTrue(added)
        let attachment = try XCTUnwrap(model.attachments.first)
        XCTAssertEqual(attachment.contentType, "image/jpeg")
        XCTAssertTrue(attachment.fileName.hasSuffix(".jpg"))
        XCTAssertTrue(attachment.isImage)
        XCTAssertNotNil(attachment.preview)
        model.stop()
    }

    func testAtMostFourImagesArePending() async {
        let model = await started()
        for _ in 0..<4 { await model.attachPastedImage(photo()) }
        let fifth = await model.attachPastedImage(photo())
        XCTAssertFalse(fifth)
        XCTAssertEqual(model.attachments.count, 4)
        XCTAssertNotNil(model.errorMessage)
        model.stop()
    }

    func testAnUnreadableImageIsRefused() async {
        let model = await started()
        let added = await model.attachPastedImage(Data("nope".utf8))
        XCTAssertFalse(added)
        XCTAssertTrue(model.attachments.isEmpty)
        model.stop()
    }

    // S4
    func testARemovedThumbnailIsNotUploaded() async throws {
        let model = await started()
        await model.attachPastedImage(photo())
        model.removeAttachment(try XCTUnwrap(model.attachments.first))
        XCTAssertTrue(model.attachments.isEmpty)
        model.draft = "just text"
        await model.send()
        XCTAssertEqual(server.count("POST /v1/uploads"), 0)
        let send = try XCTUnwrap(server.requests.last { $0.path == "/v1/chat/current/messages" })
        XCTAssertEqual((send.json["upload_ids"] as? [String]) ?? [], [])
        model.stop()
    }

    // S6
    func testAPastedImageUploadsAsJPEGAndTheTranscriptHasItsPhoto() async throws {
        let model = await started()
        await model.attachPastedImage(photo())
        model.draft = "what is this"
        await model.send()
        let upload = try XCTUnwrap(server.requests.first { $0.path == "/v1/uploads" })
        XCTAssertEqual(upload.headers["content-type"], "image/jpeg")
        XCTAssertTrue(((upload.headers["x-file-name"] ?? "").removingPercentEncoding ?? "").hasSuffix(".jpg"))
        let send = try XCTUnwrap(server.requests.last { $0.path == "/v1/chat/current/messages" })
        XCTAssertEqual((send.json["upload_ids"] as? [String])?.count, 1)
        await pasteWait { model.items.contains { $0.kind == "screenshot" } }
        let item = try XCTUnwrap(model.items.first { $0.kind == "screenshot" })
        XCTAssertNotNil(item.fileName.flatMap { model.sentPhotos[$0] }, "the phone shows its own image, not a chip")
        model.stop()
    }

    // S12
    func testTheComposerClearsAtOnceAndComesBackWhenTheSendFails() async throws {
        let model = await started()
        server.uploadDelay = 0.6
        server.uploadFails = true
        await model.attachPastedImage(photo())
        model.draft = "look"
        let sending = Task { await model.send() }
        await pasteWait { model.sending }
        XCTAssertEqual(model.draft, "", "the text clears before the upload answers")
        XCTAssertTrue(model.attachments.isEmpty, "so do the thumbnails")
        await sending.value
        XCTAssertEqual(model.draft, "look")
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertEqual(server.count("POST /v1/chat/current/messages"), 0)
        model.stop()
    }

    func testASuccessfulSendLeavesTheComposerEmpty() async {
        let model = await started()
        server.uploadDelay = 0.3
        await model.attachPastedImage(photo())
        model.draft = "look"
        await model.send()
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.attachments.isEmpty)
        model.stop()
    }

    // S13
    func testRunningFollowsTheMacAndStopCallsTheStopRoute() async {
        let model = await started()
        XCTAssertFalse(model.running)
        var snapshot = server.chat
        snapshot.running = true
        snapshot.state = "running"
        server.chat = snapshot
        server.publish(RemoteEvent.chatState)
        await pasteWait { model.running }
        XCTAssertTrue(model.running, "a turn the Mac or an automation started shows too")
        await model.stopTurn()
        XCTAssertEqual(server.count("POST /v1/chat/current/stop"), 1)
        await pasteWait { !model.running }
        XCTAssertFalse(model.running, "the turn ended")
        model.stop()
    }
}
