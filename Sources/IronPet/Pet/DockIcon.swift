import AppKit
import IronPetCore

/// The Dock and ⌘-Tab icon while the app runs: the chosen pet's idle frame. Only `NSApp.applicationIconImage` changes.
/// The app bundle and the Finder icon stay as they are.
enum DockIcon {
    static let pixels = 1024
    /// Share of each edge left empty so the pet does not touch the icon border.
    static let padding = 0.10

    /// The idle frame (row 0, column 0) scaled to fit a square canvas with padding, on a transparent background.
    /// The fit uses the pet's visible pixels, not the transparent margin of its sheet cell, so the pet fills the canvas.
    /// Nil when the sheet has no idle frame or the frame is fully transparent.
    static func render(_ atlas: Atlas) -> NSImage? {
        guard let frame = atlas.frame(.idle, 0), let visible = opaqueBounds(of: frame),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let side = Double(pixels) * (1 - 2 * padding)
        let scale = min(side / Double(visible.width), side / Double(visible.height))
        let center = Double(pixels) / 2
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: center - Double(visible.midX) * scale, y: center - Double(visible.midY) * scale,
                                       width: Double(frame.width) * scale, height: Double(frame.height) * scale))
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: pixels / 2, height: pixels / 2))
    }

    /// The box around the pixels with alpha above zero. It is in the coordinates `CGContext.draw(_:in:)` uses for an image
    /// of the frame's size, so it can be passed straight to the draw call. Nil when the frame is blank.
    private static func opaqueBounds(of frame: CGImage) -> CGRect? {
        let width = frame.width, height = frame.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for row in 0..<height {
            let line = bytes + row * context.bytesPerRow
            for column in 0..<width where line[column * 4 + 3] != 0 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The icon for `pet.sprite`. An explicit path must load as an atlas. Unset means the default pet, as in `Atlas.loadDefault`.
    static func image(forSprite sprite: String?) -> NSImage? {
        let atlas: Atlas?
        if let sprite, !sprite.isEmpty {
            atlas = Atlas.load(URL(fileURLWithPath: (sprite as NSString).expandingTildeInPath))
        } else {
            atlas = Atlas.loadDefault(sprite: nil)
        }
        return atlas.flatMap(render)
    }
}

/// Applies the icon when the pet changes. `set` is `NSApp.applicationIconImage` in the app; nil restores the default icon.
@MainActor
final class DockIconController {
    private let load: (String?) -> NSImage?
    private let set: (NSImage?) -> Void
    private var applied: String??

    init(load: @escaping (String?) -> NSImage? = DockIcon.image(forSprite:),
         set: @escaping (NSImage?) -> Void = { NSApp.applicationIconImage = $0 }) {
        self.load = load
        self.set = set
    }

    /// Renders and sets the icon for `sprite`. The same value as last time does nothing.
    func update(sprite: String?) {
        let key = sprite?.isEmpty == true ? nil : sprite
        if let applied, applied == key { return }
        applied = .some(key)
        set(load(key))
    }
}
