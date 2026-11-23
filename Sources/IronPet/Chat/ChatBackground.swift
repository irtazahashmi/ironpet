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
        if let old, old != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
            for ext in ["jpg", "png"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(phoneFolderName).appendingPathComponent("\(old).\(ext)"))
            }
        }
        return name
    }

    /// The longest side of the copy a phone downloads.
    static let phoneLongSide = 2400
    /// Where the phone copies live. A dot folder, so the backgrounds listing and `custom-*` names never include it.
    fileprivate static let phoneFolderName = ".phone"

    /// A copy of the custom image at most `phoneLongSide` px on the long side, made once per file and kept in `folder/.phone`.
    /// It is a JPEG, or a PNG when the picture has transparency, which a JPEG would turn black.
    /// Returns nil when the file is already small (under 1.5 MB and within the size), so the original is sent, or when it cannot be read.
    static func phoneCopy(of name: String, in folder: URL = ChatBackground.folder) -> URL? {
        let url = folder.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let longest = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        if bytes < 1_500_000, longest <= phoneLongSide { return nil }
        let phone = folder.appendingPathComponent(phoneFolderName)
        // The copy is made once. Which kind it is was decided then.
        for ext in ["png", "jpg"] where FileManager.default.fileExists(atPath: phone.appendingPathComponent("\(name).\(ext)").path) {
            return phone.appendingPathComponent("\(name).\(ext)")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: phoneLongSide]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // A picture with an alpha channel that is fully opaque (most screenshots) still goes as a JPEG.
        let transparent = (props?[kCGImagePropertyHasAlpha] as? Bool ?? false) && hasTransparency(cg)
        let target = phone.appendingPathComponent(name + (transparent ? ".png" : ".jpg"))
        guard let data = transparent ? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                  : NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: target)) != nil else { return nil }
        return target
    }

    /// True when any pixel is not fully opaque. The picture is shrunk to 64 px first, which still shows a clear area of any size.
    private static func hasTransparency(_ image: CGImage) -> Bool {
        let side = 64
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
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
        ChatBackgroundPicture(id: id, customImage: customImage, fallback: SharedTheme.window, scale: scale)
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
            SharedTheme.window
            ChatBackgroundView(id: store.config.chat.background, customFile: store.config.chat.customImage)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
