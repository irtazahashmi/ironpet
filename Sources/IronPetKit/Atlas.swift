import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// One animation row of a Codex v2 pet atlas.
public struct AtlasRow: Equatable, Sendable {
    public let index: Int
    public let durations: [Double]
    public let loops: Bool

    public init(index: Int, durations: [Double], loops: Bool) {
        self.index = index; self.durations = durations; self.loops = loops
    }

    public static func uniform(_ index: Int, frames: Int, each: Double, last: Double, loops: Bool = true) -> AtlasRow {
        AtlasRow(index: index, durations: Array(repeating: each, count: frames - 1) + [last], loops: loops)
    }

    public static let idle = AtlasRow(index: 0, durations: [0.28, 0.11, 0.11, 0.14, 0.14, 0.32], loops: true)
    public static let runRight = uniform(1, frames: 8, each: 0.12, last: 0.22)
    public static let runLeft = uniform(2, frames: 8, each: 0.12, last: 0.22)
    public static let waving = uniform(3, frames: 4, each: 0.14, last: 0.28, loops: false)
    public static let jumping = uniform(4, frames: 5, each: 0.14, last: 0.28, loops: false)
    public static let failed = uniform(5, frames: 8, each: 0.14, last: 0.24)
    public static let waiting = uniform(6, frames: 6, each: 0.15, last: 0.26)
    public static let running = uniform(7, frames: 6, each: 0.12, last: 0.22)
    public static let review = uniform(8, frames: 6, each: 0.15, last: 0.28)
    public static let drinking = AtlasRow(index: 11, durations: [0.3, 0.3, 0.55, 0.55, 0.35, 0.9], loops: false)
    public static let stretching = AtlasRow(index: 12, durations: [0.25, 0.25, 0.45, 0.45, 0.5, 0.5, 0.3, 0.6], loops: false)
}

/// Sliced frames of a Codex v2 atlas (1536x2288): rows 0-8 animations, rows 9-10 sixteen look directions.
/// ironpet's own art adds rows 11-12 (drinking, stretching), making it 1536x2704. The Mac app and the iPhone app both
/// decode sheets with this type, so they cut the same frames.
public struct Atlas: @unchecked Sendable {
    public static let cell = CGSize(width: 192, height: 208)
    public static let width = 1536
    public static let heights = [2288, 2704]

#if canImport(CoreGraphics)
    public let rows: [[CGImage]]
    public let look: [CGImage]

    public init?(image: CGImage) {
        guard image.width == Self.width, Self.heights.contains(image.height) else { return nil }
        func cell(_ row: Int, _ col: Int) -> CGImage? {
            image.cropping(to: CGRect(x: CGFloat(col) * Self.cell.width, y: CGFloat(row) * Self.cell.height,
                                      width: Self.cell.width, height: Self.cell.height))
        }
        let count = image.height / Int(Self.cell.height)
        rows = (0..<count).map { r in (9..<11).contains(r) ? [] : (0..<8).compactMap { cell(r, $0) } }
        look = (9..<11).flatMap { r in (0..<8).compactMap { cell(r, $0) } }
    }

    public func has(_ row: AtlasRow) -> Bool {
        row.index < rows.count && !rows[row.index].isEmpty
    }

    public func frame(_ row: AtlasRow, _ index: Int) -> CGImage? {
        guard has(row) else { return nil }
        let frames = rows[row.index]
        return frames[min(index, frames.count - 1)]
    }

    /// The atlas in a PNG or WebP file, or nil when the file is missing, unreadable or not in the atlas layout.
    public static func load(_ url: URL) -> Atlas? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source)
    }

    /// The atlas in PNG or WebP bytes.
    public static func load(data: Data) -> Atlas? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source)
    }

    private static func load(_ source: CGImageSource) -> Atlas? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Atlas(image: image)
    }

    /// The pixel size of the first image in a file, read without decoding it.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

#else
    // Linux has no CoreGraphics or ImageIO, so it cannot cut frames. It still checks that a PNG has the atlas layout, which is all
    // the core needs to import and list pets.
    public let rowCount: Int

    public init?(width: Int, height: Int) {
        guard Self.isValid(width: width, height: height) else { return nil }
        rowCount = height / Int(Self.cell.height)
    }

    public func has(_ row: AtlasRow) -> Bool { row.index < rowCount && !(9..<11).contains(row.index) }

    /// The atlas in a PNG file, or nil when the file is missing, unreadable, not a PNG or not in the atlas layout.
    public static func load(_ url: URL) -> Atlas? {
        guard let size = pixelSize(of: url) else { return nil }
        return Atlas(width: size.width, height: size.height)
    }

    /// The atlas in PNG bytes.
    public static func load(data: Data) -> Atlas? {
        guard let size = pngSize(data) else { return nil }
        return Atlas(width: size.width, height: size.height)
    }

    /// The pixel size of a PNG file, read from its header without decoding it.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 24) else { return nil }
        return pngSize(head)
    }

    private static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count == 24, Array(bytes[0..<8]) == signature else { return nil }
        func value(_ at: Int) -> Int { bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        return (value(16), value(20))
    }
#endif

    /// Whether a pixel size is one of the atlas layouts.
    public static func isValid(width: Int, height: Int) -> Bool { width == Self.width && heights.contains(height) }
}

/// Which row plays for a mood name from `GET /v1/pet` or the `pet.mood` event. It follows the Mac's `PetMood`: an atlas without
/// the extra rows (Codex pets, 2288 high) plays waving where the Mac's pet would drink or stretch.
public enum PetAnimation {
    public static func row(forMood mood: String) -> AtlasRow {
        switch mood {
        case "working": return .running
        case "needsInput": return .waiting
        case "done": return .jumping
        case "failed": return .failed
        case "listening": return .waving
        case "drinking": return .drinking
        case "stretching": return .stretching
        case "attentive": return .review
        default: return .idle
        }
    }

    /// The row to settle into after a one-shot row finishes.
    public static func followUp(forMood mood: String) -> AtlasRow? {
        switch mood {
        case "done": return .review
        case "listening": return .idle
        default: return nil
        }
    }

    /// The row for `mood` on `atlas`, with the waving fallback for a sheet that lacks it.
    public static func row(forMood mood: String, in atlas: Atlas?) -> AtlasRow {
        let wanted = row(forMood: mood)
        guard let atlas, !atlas.has(wanted) else { return wanted }
        return .waving
    }
}

/// Which frame shows `elapsed` seconds after a mood started. A looping row repeats. A one-shot row plays once, then settles into its
/// follow-up row (looping) or holds its last frame, as the Mac's pet does.
public enum SpriteTimeline {
    public struct Position: Equatable, Sendable {
        public var row: AtlasRow
        public var frame: Int
        public init(row: AtlasRow, frame: Int) { self.row = row; self.frame = frame }
    }

    public static func position(row: AtlasRow, followUp: AtlasRow? = nil, elapsed: Double) -> Position {
        let total = row.durations.reduce(0, +)
        guard total > 0, elapsed >= 0 else { return Position(row: row, frame: 0) }
        if row.loops { return Position(row: row, frame: frame(in: row, at: elapsed.truncatingRemainder(dividingBy: total))) }
        if elapsed < total { return Position(row: row, frame: frame(in: row, at: elapsed)) }
        guard let followUp, followUp.durations.reduce(0, +) > 0 else { return Position(row: row, frame: row.durations.count - 1) }
        let rest = elapsed - total
        if followUp.loops { return Position(row: followUp, frame: frame(in: followUp, at: rest.truncatingRemainder(dividingBy: followUp.durations.reduce(0, +)))) }
        return Position(row: followUp, frame: rest < followUp.durations.reduce(0, +) ? frame(in: followUp, at: rest) : followUp.durations.count - 1)
    }

    private static func frame(in row: AtlasRow, at time: Double) -> Int {
        var t = time
        for (index, duration) in row.durations.enumerated() {
            if t < duration { return index }
            t -= duration
        }
        return row.durations.count - 1
    }
}
