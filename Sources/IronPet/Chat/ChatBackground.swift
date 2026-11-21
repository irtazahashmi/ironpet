import AppKit
import ImageIO
import IronPetCore
import IronPetKit
import SwiftUI

/// The picture behind the chat transcript: a built-in gradient with an optional tiled doodle pattern, or an image the
/// user picked. The built-in table and its drawing live in IronPetKit (`ChatBackgrounds`), so the iPhone app draws the same
/// ones. This type keeps what only the Mac does: importing an image and caching the decoded custom image.
extension ChatBackground {
    enum ImportError: LocalizedError {
        case notAnImage
        var errorDescription: String? { "That file is not an image ironpet can read." }
    }

    /// Copies `source` into `folder` under a fresh name and returns the file name. Moving or deleting the original
    /// afterwards does not affect the background. Removes the previously imported image.
    static func importImage(from source: URL, into folder: URL = ChatBackground.folder, replacing old: String? = nil) throws -> String {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
            throw ImportError.notAnImage
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let keepsFormat = ["png", "jpg", "jpeg"].contains(ext)
        let name = "custom-\(UUID().uuidString.prefix(8))." + (keepsFormat ? ext : "png")
        let target = folder.appendingPathComponent(name)
        if keepsFormat {
            try FileManager.default.copyItem(at: source, to: target)
        } else {
            // Other formats are stored as PNG.
            guard let cg = CGImageSourceCreateImageAtIndex(image, 0, nil),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw ImportError.notAnImage }
            try data.write(to: target)
        }
        if let old, old != name { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        return name
    }

    /// Decoded custom images, at most 2400 px on the long side, so a 40 MP photo does not sit in memory at full size.
    @MainActor private static var imageCache: [String: NSImage] = [:]

    @MainActor
    static func customImage(named name: String, in folder: URL = ChatBackground.folder) -> NSImage? {
        if let cached = imageCache[name] { return cached }
        let url = folder.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2400]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        imageCache = [name: image]
        return image
    }
}

/// Draws the chosen background. `scale` shrinks the doodles for thumbnails.
struct ChatBackgroundView: View {
    let id: String
    var customFile: String?
    var scale: CGFloat = 1

    var body: some View {
        ChatBackgroundPicture(id: id, customImage: customImage, fallback: Color(nsColor: .windowBackgroundColor), scale: scale)
    }

    private var customImage: Image? {
        guard id == ChatBackground.customID, let customFile, let image = ChatBackground.customImage(named: customFile) else { return nil }
        return Image(nsImage: image)
    }
}

/// The chat's backdrop. Observes the config itself so a change in Settings shows at once without redrawing the
/// transcript above it.
struct ChatBackdrop: View {
    @ObservedObject private var store = SettingsAPI.live

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            ChatBackgroundView(id: store.config.chat.background, customFile: store.config.chat.customImage)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
