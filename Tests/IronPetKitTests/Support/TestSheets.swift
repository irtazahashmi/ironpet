import CoreGraphics
import Foundation
import ImageIO
import IronPetKit
import UniformTypeIdentifiers

/// Sprite sheets drawn in code, so tests need no binary fixtures. Every 192x208 cell is one flat color that names its row and column,
/// which lets a test tell which frame a row plays.
enum TestSheets {
    /// The color of a cell: red is the row, green is the column, blue is fixed.
    static func color(row: Int, column: Int) -> (r: UInt8, g: UInt8, b: UInt8) { (UInt8(10 + row * 15), UInt8(10 + column * 25), 200) }

    /// A 1536 wide sheet of the given height: 2704 is ironpet's own layout (Ghost), 2288 a Codex sheet.
    static func image(height: Int) -> CGImage {
        let width = Atlas.width
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(row: y / Int(Atlas.cell.height), column: x / Int(Atlas.cell.width))
                let i = (y * width + x) * 4
                pixels[i] = c.r; pixels[i + 1] = c.g; pixels[i + 2] = c.b; pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func png(height: Int, width: Int = Atlas.width) -> Data {
        let image = width == Atlas.width ? image(height: height) : resized(image(height: height), width: width)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func resized(_ image: CGImage, width: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return context.makeImage()!
    }

    /// The RGB of the middle pixel of a frame.
    static func center(of frame: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(frame, in: CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height))
        return (pixel[0], pixel[1], pixel[2])
    }
}
