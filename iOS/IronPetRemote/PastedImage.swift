import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// An image from the clipboard, ready to upload: JPEG, or PNG when the picture has transparency.
struct NormalizedImage: Equatable {
    var data: Data
    var contentType: String
    var fileExtension: String
    /// Pixel size of the encoded image.
    var width: Int
    var height: Int
}

/// Turns pasted image bytes into something the Mac's agent accepts. ACP image blocks take png, jpeg, gif and webp only, so a pasted
/// HEIC becomes JPEG. The long side is capped at 2048 px and the bytes at 2 MB. The result carries no EXIF, GPS or other metadata:
/// the encoder is given pixels and nothing else, and the pixels are already upright.
enum PastedImage {
    static let maxLongSide = 2048
    static let maxBytes = 2_000_000
    static let startQuality: CGFloat = 0.8
    /// Below this the picture is unreadable anyway, so the loop stops shrinking.
    private static let minLongSide = 256

    static func normalize(data: Data) -> NormalizedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return encode(longSide: maxLongSide) { side in
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            // Applies the EXIF orientation, so the output needs no orientation tag.
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: side]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }

    /// A small image for the composer's thumbnail row.
    static func thumbnail(from data: Data, longSide: Int = 160) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longSide]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    // MARK: Encoding

    /// Encodes the picture at `longSide`, then lowers the JPEG quality and finally the size until it fits in `maxBytes`.
    private static func encode(longSide: Int, picture: (Int) -> CGImage?) -> NormalizedImage? {
        var side = longSide
        while true {
            guard let image = picture(side), let flat = flatten(image) else { return nil }
            let longest = max(flat.image.width, flat.image.height)
            var quality = startQuality
            while true {
                guard let data = flat.transparent ? png(flat.image) : jpeg(flat.image, quality: quality) else { return nil }
                if data.count <= maxBytes || (longest <= minLongSide && quality <= 0.3) {
                    return NormalizedImage(data: data, contentType: flat.transparent ? "image/png" : "image/jpeg",
                                           fileExtension: flat.transparent ? "png" : "jpg", width: flat.image.width, height: flat.image.height)
                }
                // A PNG has no quality, so only a smaller size helps it.
                if flat.transparent || quality <= 0.5 { break }
                quality -= 0.1
            }
            guard longest > minLongSide else { return nil }
            side = max(minLongSide, Int(Double(longest) * 0.8))
        }
    }

    /// Draws into 8-bit RGBA and reports whether any pixel is not fully opaque. An opaque picture is copied into RGB without an alpha channel, which is what the JPEG encoder wants.
    private static func flatten(_ image: CGImage) -> (image: CGImage, transparent: Bool)? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info),
              let base = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var transparent = false
        var offset = 3
        let end = width * height * 4
        while offset < end {
            if pixels[offset] != 255 { transparent = true; break }
            offset += 4
        }
        guard let drawn = context.makeImage() else { return nil }
        guard !transparent else { return (drawn, true) }
        guard let opaque = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        opaque.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
        return opaque.makeImage().map { ($0, false) }
    }

    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        encode(image, type: UTType.jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func png(_ image: CGImage) -> Data? { encode(image, type: UTType.png, options: [:]) }

    /// The destination is given the pixels and these options only, so no source metadata can reach the output.
    private static func encode(_ image: CGImage, type: UTType, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// What a paste in the message field does. Decided from what the clipboard holds, never by reading it ahead of time: iOS asks the
/// user for permission whenever an app reads the clipboard on its own, and a paste the user started needs no prompt.
enum ComposerPaste {
    struct Decision: Equatable {
        var attachImage: Bool
        var insertText: Bool
    }

    /// An image is attached. Text that came with it, as Safari copies a picture with its address, is pasted too. A clipboard without an
    /// image behaves as before and the text field pastes whatever it can.
    static func decide(hasImage: Bool, hasText: Bool) -> Decision {
        hasImage ? Decision(attachImage: true, insertText: hasText) : Decision(attachImage: false, insertText: true)
    }

    /// The types read as raw bytes first, so a JPEG keeps its EXIF orientation for the normaliser to apply.
    private static let rawTypes = [UTType.png, .jpeg, .heic].map(\.identifier)

    /// Runs one paste. Calls `attach` with the image bytes when the clipboard holds an image and returns whether the text field should
    /// paste its text as well.
    @discardableResult
    static func handle(_ pasteboard: UIPasteboard, attach: (Data) -> Void) -> Bool {
        let decision = decide(hasImage: pasteboard.hasImages, hasText: pasteboard.hasStrings)
        guard decision.attachImage else { return decision.insertText }
        if let data = imageData(pasteboard) {
            attach(data)
            return decision.insertText
        }
        // An image the app cannot read must not swallow the paste.
        return pasteboard.hasStrings
    }

    static func imageData(_ pasteboard: UIPasteboard) -> Data? {
        for type in rawTypes {
            if let data = pasteboard.data(forPasteboardType: type), !data.isEmpty { return data }
        }
        // Any other image type comes decoded. `pngData()` writes the pixels upright.
        return pasteboard.image?.pngData()
    }
}
