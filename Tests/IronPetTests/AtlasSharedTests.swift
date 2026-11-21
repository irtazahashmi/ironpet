import AppKit
import XCTest
@testable import IronPet
@testable import IronPetCore

/// The Mac cuts sprite sheets with the `Atlas` of IronPetKit, which the iPhone app uses too. Before the move the Mac decoded a sheet with
/// `NSImage`; these tests check that both paths yield the same frames for the Ghost layout (1536x2704) and a Codex sheet (1536x2288).
final class AtlasSharedTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-atlas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A sheet whose every pixel depends on its position, so a frame cut from the wrong place differs.
    private func writeSheet(height: Int, name: String) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.bitmapData)
        for y in 0..<height {
            for x in 0..<1536 {
                let i = y * rep.bytesPerRow + x * 4
                data[i] = UInt8((x * 7 + y) % 251); data[i + 1] = UInt8((x + y * 3) % 241); data[i + 2] = UInt8((x / 192 * 30 + y / 208 * 10) % 255); data[i + 3] = 255
            }
        }
        let url = root.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func legacy(_ url: URL) -> Atlas? {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return Atlas(image: cg)
    }

    func testBothDecodersCutTheSameFramesFromAGhostAndACodexSheet() throws {
        for height in [2704, 2288] {
            let url = try writeSheet(height: height, name: "\(height).png")
            let shared = try XCTUnwrap(Atlas.load(url))
            let old = try XCTUnwrap(legacy(url))
            XCTAssertEqual(shared.rows.map(\.count), old.rows.map(\.count), "frames per row at \(height)")
            XCTAssertEqual(shared.look.count, old.look.count)
            XCTAssertEqual(shared.rows.count, height / 208)
            for (rowIndex, row) in shared.rows.enumerated() {
                for (index, frame) in row.enumerated() {
                    XCTAssertEqual(pixels(frame), pixels(old.rows[rowIndex][index]), "row \(rowIndex) frame \(index) at \(height)")
                }
            }
            for (index, frame) in shared.look.enumerated() { XCTAssertEqual(pixels(frame), pixels(old.look[index]), "look \(index)") }
        }
    }

    func testTheMacKeepsRejectingOtherSizesAndMissingFiles() throws {
        XCTAssertNil(Atlas.load(try writeSheet(height: 2000, name: "short.png")))
        XCTAssertNil(Atlas.load(root.appendingPathComponent("missing.png")))
        let junk = root.appendingPathComponent("junk.png")
        try Data("junk".utf8).write(to: junk)
        XCTAssertNil(Atlas.load(junk))
    }

    func testAnAtlasWithoutTheExtraRowsFallsBackToWavingOnTheMac() throws {
        let codex = try XCTUnwrap(Atlas.load(try writeSheet(height: 2288, name: "codex.png")))
        XCTAssertFalse(codex.has(PetMood.drinking.row))
        XCTAssertEqual(PetMood.drinking.fallbackRow, .waving)
        XCTAssertEqual(PetMood.failed.row.index, 5)
    }
}
