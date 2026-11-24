import Foundation
import ImageIO
import IronPetKit
import UIKit

/// Images the Mac holds for chat attachments: a screenshot it took or a file the user attached there. The phone asks for one by the
/// id of its message, keeps the bytes in memory while the app runs, and draws the inline thumbnail from them with ImageIO, so a long
/// chat does not decode every screenshot at full size.
@MainActor
final class ChatImages {
    enum Failure: Error, Equatable {
        /// The Mac said no: the file is gone, or the message has none. The text is the Mac's own.
        case refused(String)
        /// The phone could not reach the Mac, or could not read the bytes as a picture.
        case unavailable(String)

        var message: String {
            switch self {
            case .refused(let text), .unavailable(let text): return text
            }
        }
    }

    /// The tallest side of the inline thumbnail in pixels, 110 pt at 3x.
    static let thumbnailPixels = 330
    /// The tallest side of the full-screen picture in pixels. Enough to zoom on a phone, and it bounds the memory of a 5K screenshot.
    static let fullPixels = 3000

    private let fetch: @Sendable (String) async throws -> Data
    private let bytes = NSCache<NSString, NSData>()
    private let thumbnails = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<Data, Error>] = [:]
    /// The Mac allows a token a burst of 20 requests, so a chat full of screenshots asks three at a time.
    static let maxDownloads = 3
    private var downloading = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(client: IronPetClient) {
        fetch = { id in try await client.downloadChatImage(messageID: id) }
        bytes.totalCostLimit = 64 << 20
        thumbnails.countLimit = 200
    }

    /// For tests: any source of bytes.
    init(fetch: @escaping @Sendable (String) async throws -> Data) {
        self.fetch = fetch
        bytes.totalCostLimit = 64 << 20
        thumbnails.countLimit = 200
    }

    func thumbnail(for id: String) async -> Result<UIImage, Failure> {
        if let cached = thumbnails.object(forKey: id as NSString) { return .success(cached) }
        switch await data(for: id) {
        case .failure(let failure): return .failure(failure)
        case .success(let data):
            guard let image = await Self.decode(data, maxPixels: Self.thumbnailPixels) else { return .failure(.unavailable("The phone could not read this image.")) }
            thumbnails.setObject(image, forKey: id as NSString)
            return .success(image)
        }
    }

    func full(for id: String) async -> Result<UIImage, Failure> {
        switch await data(for: id) {
        case .failure(let failure): return .failure(failure)
        case .success(let data):
            guard let image = await Self.decode(data, maxPixels: Self.fullPixels) else { return .failure(.unavailable("The phone could not read this image.")) }
            return .success(image)
        }
    }

    /// The raw bytes, fetched once however many rows ask at the same time.
    func data(for id: String) async -> Result<Data, Failure> {
        if let cached = bytes.object(forKey: id as NSString) { return .success(cached as Data) }
        let task: Task<Data, Error>
        if let running = inFlight[id] { task = running } else {
            let fetch = fetch
            task = Task { [self] in
                await acquire()
                defer { release() }
                return try await fetch(id)
            }
            inFlight[id] = task
        }
        defer { inFlight[id] = nil }
        do {
            let data = try await task.value
            bytes.setObject(data as NSData, forKey: id as NSString, cost: data.count)
            return .success(data)
        } catch let error as ClientError {
            if case .api(_, _, let message) = error { return .failure(.refused(message)) }
            return .failure(.unavailable(PlainError.message(for: error)))
        } catch {
            return .failure(.unavailable(PlainError.message(for: error)))
        }
    }

    /// A picture the phone already holds, at the full-screen size.
    static func decodeFull(_ data: Data) async -> UIImage? { await decode(data, maxPixels: fullPixels) }

    private func acquire() async {
        if downloading < Self.maxDownloads { downloading += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { downloading -= 1 } else { waiting.removeFirst().resume() }
    }

    /// `downsample` off the main actor, so a large screenshot does not stall scrolling.
    nonisolated static func decode(_ data: Data, maxPixels: Int) async -> UIImage? {
        await Task.detached { downsample(data, maxPixels: maxPixels) }.value
    }

    /// Decodes at most `maxPixels` on the long side, with the orientation applied. Nil when the bytes are not a picture.
    nonisolated static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
