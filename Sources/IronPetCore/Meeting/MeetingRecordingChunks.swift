import Foundation
import IronPetKit

/// Audio chunks that arrive from a recording on the phone. Each recording is a folder `<id>/` with one `NNNNNN.wav` per chunk, named by
/// the index the phone gave it. A chunk is written once: a chunk sent again, because the answer was lost, finds the file and changes
/// nothing, so the Mac ends up with every chunk exactly once, in index order.
package final class MeetingRecordingChunks: @unchecked Sendable {
    package init(folder: URL) {
        self.folder = folder
    }

    package let folder: URL
    private let lock = NSLock()

    /// Most chunks one recording may have: 4 hours of 30 second chunks, with room for a longer chunk length later.
    package static let maxChunks = 2000

    package enum Failure: Error, Equatable {
        case invalid(String)
        /// Chunks that have not arrived yet.
        case missing([Int])
    }

    /// Keeps chunk `index` of recording `id`. Returns true when it was new and false when the Mac already held it.
    @discardableResult
    package func store(id: String, index: Int, wav: Data) throws -> Bool {
        try lock.withLock {
            let id = try checked(id)
            guard (0..<Self.maxChunks).contains(index) else { throw Failure.invalid("the chunk index must be from 0 to \(Self.maxChunks - 1)") }
            guard Self.isChunk(wav) else { throw Failure.invalid("a chunk must be a 16 kHz mono 16-bit WAV file") }
            let url = file(id, index)
            if FileManager.default.fileExists(atPath: url.path) { return false }
            try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
            try wav.write(to: url, options: .atomic)
            return true
        }
    }

    /// The chunk files `0..<count` in order. Throws `missing` with the indexes that are not here.
    package func files(id: String, count: Int) throws -> [URL] {
        try lock.withLock {
            let id = try checked(id)
            guard (1...Self.maxChunks).contains(count) else { throw Failure.invalid("a recording has from 1 to \(Self.maxChunks) chunks") }
            let urls = (0..<count).map { file(id, $0) }
            let missing = (0..<count).filter { !FileManager.default.fileExists(atPath: urls[$0].path) }
            guard missing.isEmpty else { throw Failure.missing(missing) }
            return urls
        }
    }

    package func discard(id: String) {
        lock.withLock { if let id = try? checked(id) { try? FileManager.default.removeItem(at: dir(id)) } }
    }

    /// Deletes recordings that were never completed and not touched for `age` seconds.
    package func removeStale(olderThan age: TimeInterval, now: Date = Date()) {
        lock.withLock {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: entry) }
            }
        }
    }

    /// A 16 kHz mono 16-bit WAV with audio in it. The phone's recorder writes exactly this.
    private static func isChunk(_ wav: Data) -> Bool {
        guard wav.count > 44, wav.prefix(4) == Data("RIFF".utf8), WAV.duration(of: wav) != nil else { return false }
        let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        return rate == UInt32(WAV.sampleRate) && wav[wav.startIndex + 22] == 1 && wav[wav.startIndex + 34] == 16
    }

    // The id names a folder, so only a UUID is accepted.
    private func checked(_ id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw Failure.invalid("the recording id must be a UUID") }
        return id.uppercased()
    }

    private func dir(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }
    private func file(_ id: String, _ index: Int) -> URL { dir(id).appendingPathComponent(String(format: "%06d.wav", index)) }
}
