import AppKit
import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class DockIconTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A 1536x2704 sheet that is opaque red inside the given cells (row, column) and transparent elsewhere.
    private func sheet(filledCells: [(Int, Int)]) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 2704, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        for (row, column) in filledCells {
            for y in (row * 208 + 20)..<(row * 208 + 188) {
                for x in (column * 192 + 20)..<(column * 192 + 172) {
                    rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
                }
            }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func write(_ cells: [(Int, Int)], as name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try sheet(filledCells: cells).write(to: url)
        return url.path
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return NSBitmapImageRep(cgImage: cg)
    }

    /// A sheet whose idle frame is opaque inside `size` (width, height), centred in the 192x208 cell.
    private func writeIdle(width: Int, height: Int, as name: String) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 2704, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let x0 = (192 - width) / 2, y0 = (208 - height) / 2
        for y in y0..<(y0 + height) {
            for x in x0..<(x0 + width) { rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: x, y: y) }
        }
        let url = root.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }

    /// The box around pixels with alpha above zero, in image pixels (y down).
    private func opaqueBox(_ image: NSImage) throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let rep = try bitmap(image)
        XCTAssertEqual(rep.pixelsWide, 1024)
        XCTAssertEqual(rep.pixelsHigh, 1024)
        var minX = 1024, maxX = -1, minY = 1024, maxY = -1
        for y in 0..<1024 {
            for x in 0..<1024 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return (minX, maxX, minY, maxY)
    }

    /// Asserts the pet sits inside the icon grid's pet box, is centred, and touches that box on its longer side.
    private func assertFits(_ sprite: String, aspect: Double? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(DockIcon.image(forSprite: sprite), file: file, line: line)
        let box = try opaqueBox(image)
        let low = (1024 - DockIcon.petSide) / 2 - 4, high = (1024 + DockIcon.petSide) / 2 + 4
        XCTAssertGreaterThanOrEqual(Double(box.minX), low, file: file, line: line)
        XCTAssertLessThanOrEqual(Double(box.maxX), high, file: file, line: line)
        XCTAssertGreaterThanOrEqual(Double(box.minY), low, file: file, line: line)
        XCTAssertLessThanOrEqual(Double(box.maxY), high, file: file, line: line)
        XCTAssertEqual(Double(box.minX + box.maxX) / 2, 511.5, accuracy: 2, "centred horizontally", file: file, line: line)
        XCTAssertEqual(Double(box.minY + box.maxY) / 2, 511.5, accuracy: 2, "centred vertically", file: file, line: line)
        let width = Double(box.maxX - box.minX + 1), height = Double(box.maxY - box.minY + 1)
        XCTAssertGreaterThanOrEqual(max(width, height), DockIcon.petSide - 4, "the pet fills its box", file: file, line: line)
        if let aspect { XCTAssertEqual(width / height, aspect, accuracy: aspect * 0.04, "aspect ratio kept", file: file, line: line) }
    }

    func testRendersTheIdleFrameInsideTheIconGridOnATransparentCanvas() throws {
        let path = try write([(0, 0), (1, 0), (0, 1)], as: "pet.png")
        try assertFits(path, aspect: 152.0 / 168.0)
        let image = try XCTUnwrap(DockIcon.image(forSprite: path))
        let rep = try bitmap(image)
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        XCTAssertEqual(rep.colorAt(x: 1023, y: 1023)?.alphaComponent, 0)
        XCTAssertEqual(rep.colorAt(x: 100, y: 512)?.alphaComponent, 0, "nothing outside the 824 grid")
        // The pet box lies inside the grid's rounded rectangle, so all four corners clear the rounded corners.
        let grid = (1024 - DockIcon.gridSide) / 2
        let box = try opaqueBox(image)
        XCTAssertGreaterThanOrEqual(Double(box.minX), grid + DockIcon.gridCornerRadius * (1 - 1 / 2.0.squareRoot()) - 2)
    }

    func testALopsidedPetIsCentredVerticallyToo() throws {
        // Opaque only in the top 60 rows of the 208 high cell, so a flipped y axis would push the pet off the canvas.
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 2704, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        for y in 5..<65 { for x in 40..<150 { rep.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: x, y: y) } }
        let url = root.appendingPathComponent("top.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        try assertFits(url.path, aspect: 110.0 / 60.0)
    }

    func testTallWideAndSquareSheetsAllFitTheSameBoundsAndKeepTheirAspect() throws {
        try assertFits(try writeIdle(width: 40, height: 200, as: "tall.png"), aspect: 0.2)
        try assertFits(try writeIdle(width: 190, height: 30, as: "wide.png"), aspect: 190.0 / 30.0)
        try assertFits(try writeIdle(width: 120, height: 120, as: "square.png"), aspect: 1)
    }

    func testEveryBundledPetFitsTheSameBounds() throws {
        // scripts/bundle.sh draws the pets with tools/make_pet.swift and no sheet is in git, so draw them here the same way.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let generator = repo.appendingPathComponent("tools/make_pet.swift").path
        let binary = root.appendingPathComponent("make_pet").path
        try run("/usr/bin/xcrun", ["swiftc", "-O", generator, "-o", binary])
        for pet in ["ghost", "mochi", "hamster", "panda", "bunny", "cat"] {
            let sheet = root.appendingPathComponent("\(pet).png").path
            try run(binary, [pet, sheet])
            try assertFits(sheet)
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " "))")
    }

    func testOnlyTheIdleFrameContributesPixels() throws {
        let other = try write([(1, 0), (0, 1), (3, 3)], as: "other.png")
        XCTAssertNil(DockIcon.image(forSprite: other), "a sheet with a blank idle frame has no icon")
        let idle = try write([(0, 0)], as: "idle.png")
        XCTAssertNotNil(DockIcon.image(forSprite: idle))
    }

    func testMissingOrInvalidSheetGivesNoIcon() throws {
        XCTAssertNil(DockIcon.image(forSprite: root.appendingPathComponent("missing.png").path))
        let bad = root.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        XCTAssertNil(DockIcon.image(forSprite: bad.path))
    }

    func testControllerSetsTheIconOncePerChange() throws {
        let a = try write([(0, 0)], as: "a.png")
        let b = try write([(0, 0)], as: "b.png")
        var loads: [String?] = []
        var sets = 0
        var last: NSImage?
        let controller = DockIconController(load: { loads.append($0); return DockIcon.image(forSprite: $0) },
                                            set: { sets += 1; last = $0 })
        controller.update(sprite: a)
        controller.update(sprite: a)
        XCTAssertEqual(sets, 1)
        XCTAssertNotNil(last)
        controller.update(sprite: b)
        XCTAssertEqual(sets, 2)
        let tall = try writeIdle(width: 40, height: 200, as: "tall.png")
        controller.update(sprite: tall)
        XCTAssertEqual(sets, 3)
        let box = try opaqueBox(try XCTUnwrap(last))
        XCTAssertGreaterThanOrEqual(Double(box.minY), (1024 - DockIcon.petSide) / 2 - 2, "the new pet follows the same bounds")
        XCTAssertLessThanOrEqual(Double(box.maxY), (1024 + DockIcon.petSide) / 2 + 2)
        controller.update(sprite: b)
        XCTAssertEqual(sets, 4)
        XCTAssertEqual(loads, [a, b, tall, b])
        controller.update(sprite: root.appendingPathComponent("missing.png").path)
        XCTAssertEqual(sets, 5)
        XCTAssertNil(last, "an unreadable sheet restores the default icon")
    }

    func testEmptyAndNilSpriteShareOneKey() {
        var sets = 0
        let controller = DockIconController(load: { _ in nil }, set: { _ in sets += 1 })
        controller.update(sprite: nil)
        controller.update(sprite: "")
        XCTAssertEqual(sets, 1)
    }
}
