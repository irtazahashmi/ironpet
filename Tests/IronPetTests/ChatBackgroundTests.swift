import AppKit
import IronPetKit
import SwiftUI
import XCTest
@testable import IronPet
@testable import IronPetCore

final class ChatBackgroundTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makePNG(_ name: String) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = dir.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testDefaultIsPlain() {
        XCTAssertEqual(Config().chat.background, "default")
        XCTAssertNil(Config().chat.customImage)
    }

    func testChoiceSurvivesSaveAndLoad() throws {
        var config = Config()
        config.chat.background = "paws"
        let file = dir.appendingPathComponent("config.json")
        try config.save(to: file)
        XCTAssertEqual(Config.load(from: file).config.chat.background, "paws")
        try Config().save(to: file)
        XCTAssertEqual(Config.load(from: file).config.chat.background, "default")
    }

    func testUnknownBackgroundFallsBackToDefault() throws {
        let file = dir.appendingPathComponent("config.json")
        try #"{"chat": {"background": "nope"}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(from: file).config.chat.background, "default")
        try #"{"chat": {"background": "custom"}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(from: file).config.chat.background, "default", "custom without an image")
    }

    func testCustomImageKeepsOnlyTheFileName() throws {
        let file = dir.appendingPathComponent("config.json")
        try #"{"chat": {"background": "custom", "customImage": "../../secret.png"}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(from: file).config.chat.customImage, "secret.png")
        try #"{"chat": {"background": "custom", "customImage": ".."}}"#.write(to: file, atomically: true, encoding: .utf8)
        let loaded = Config.load(from: file).config.chat
        XCTAssertNil(loaded.customImage)
        XCTAssertEqual(loaded.background, "default")
    }

    func testImportCopiesImageAndOriginalCanMove() throws {
        let original = try makePNG("photo.png")
        let store = dir.appendingPathComponent("backgrounds")
        let name = try ChatBackground.importImage(from: original, into: store)
        try FileManager.default.removeItem(at: original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(name).path))
        let image = MainActor.assumeIsolated { ChatBackground.customImage(named: name, in: store) }
        XCTAssertNotNil(image)
    }

    func testImportReplacesPreviousImage() throws {
        let store = dir.appendingPathComponent("backgrounds")
        let first = try ChatBackground.importImage(from: try makePNG("a.png"), into: store)
        let second = try ChatBackground.importImage(from: try makePNG("b.png"), into: store, replacing: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(second).path))
    }

    func testImportRejectsNonImage() throws {
        let text = dir.appendingPathComponent("note.png")
        try "not an image".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ChatBackground.importImage(from: text, into: dir.appendingPathComponent("b")))
    }

    func testBuiltInsHaveUniqueIDsAndAPlainGradient() {
        XCTAssertEqual(Set(ChatBackground.builtIns.map(\.id)).count, ChatBackground.builtIns.count)
        XCTAssertTrue(ChatBackground.builtIns.contains { $0.doodles.isEmpty })
        XCTAssertGreaterThanOrEqual(ChatBackground.builtIns.count, 4)
    }

    /// S8: the Mac draws from IronPetKit's table, so the phone draws the same ones.
    func testTheMacUsesTheSharedTable() {
        XCTAssertEqual(ChatBackground.builtIns.map(\.id), ChatBackgrounds.builtIns.map(\.id))
        XCTAssertEqual(ChatBackground.builtIns.map(\.light.0), ChatBackgrounds.builtIns.map(\.light.0))
        XCTAssertEqual(ChatBackground.builtIns.map(\.dark.1), ChatBackgrounds.builtIns.map(\.dark.1))
        XCTAssertEqual(ChatBackground.builtIns.map { $0.doodles.count }, ChatBackgrounds.builtIns.map { $0.doodles.count })
        XCTAssertEqual(ChatBackground.defaultID, ChatBackgrounds.defaultID)
        XCTAssertEqual(ChatBackground.customID, ChatBackgrounds.customID)
    }

    /// Renders every built-in in light and dark, as the Mac chat draws it. With `IRONPET_BACKGROUND_RENDERS` set to a folder, the
    /// PNGs are kept there for a side-by-side look at the phone's screenshots.
    @MainActor
    func testEveryBuiltInRendersInLightAndDark() throws {
        let keep = ProcessInfo.processInfo.environment["IRONPET_BACKGROUND_RENDERS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let keep { try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true) }
        for id in ChatBackground.builtIns.map(\.id) + [ChatBackground.defaultID] {
            for scheme in [ColorScheme.light, .dark] {
                let view = ChatBackgroundView(id: id).environment(\.colorScheme, scheme).frame(width: 390, height: 700)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage, "\(id) \(scheme)")
                XCTAssertEqual(image.size.width, 390)
                if let keep, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: keep.appendingPathComponent("mac-\(id)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }

    private func writePNG(width: Int, height: Int, alpha: Bool, to url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let data = rep.bitmapData {
            for index in stride(from: 0, to: rep.bytesPerRow * height, by: 4) { data[index] = 200; data[index + 1] = 40; data[index + 2] = 40; data[index + 3] = alpha ? 0 : 255 }
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testThePhoneCopyOfATransparentImageStaysAPNGAndOfAnOpaqueOneIsAJPEG() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writePNG(width: 3000, height: 1000, alpha: true, to: dir.appendingPathComponent("clear.png"))
        try writePNG(width: 3000, height: 1000, alpha: false, to: dir.appendingPathComponent("solid.png"))
        let clear = try XCTUnwrap(ChatBackground.phoneCopy(of: "clear.png", in: dir))
        XCTAssertEqual(clear.pathExtension, "png", "a JPEG has no alpha and would turn the clear pixels black")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(clear as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2400)
        let alpha = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 10, y: 10)?.alphaComponent)
        XCTAssertEqual(alpha, 0, accuracy: 0.01, "the transparency survives")
        XCTAssertEqual(try XCTUnwrap(ChatBackground.phoneCopy(of: "solid.png", in: dir)).pathExtension, "jpg")
        // Importing a new image removes the old phone copy, whichever kind it is.
        _ = try ChatBackground.importImage(from: dir.appendingPathComponent("solid.png"), into: dir, replacing: "clear.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clear.path))
    }
}
