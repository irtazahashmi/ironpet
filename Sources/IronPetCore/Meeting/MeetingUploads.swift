import Foundation
import IronPetKit

/// Audio files that arrive from the phone in parts. Each upload is a folder `<id>/` with `meta.json` and the bytes so far, so the
/// amount held is the size of the file on disk and survives a restart of the app. Parts must arrive in order: a part whose offset is
/// not the amount held is refused, which is how a part sent twice never lands twice.
package final class MeetingUploads: @unchecked Sendable {
    package init(folder: URL) {
        self.folder = folder
    }

    package let folder: URL
    private let lock = NSLock()

    private struct Meta: Codable { var fileName: String; var size: Int64 }

    package enum Failure: Error, Equatable {
        case invalid(String)
        case notFound
        /// The offset is not the amount held. `held` is what the phone must continue from.
        case offset(held: Int64)
    }

    /// Starts an upload, or returns the one with this id when the phone asks again after a lost answer.
    package func begin(id: String, fileName: String, size: Int64) throws -> RemoteUploadStatus {
        try lock.withLock {
            let id = try checked(id)
            let name = (fileName as NSString).lastPathComponent
            if let refusal = MeetingUploadLimits.refusal(fileName: name, size: size) { throw Failure.invalid(refusal) }
            if size <= 0 { throw Failure.invalid(MeetingUploadLimits.unreadable(name)) }
            if let meta = meta(id) {
                guard meta.fileName == name, meta.size == size else { throw Failure.invalid("an upload with this id already holds a different file") }
                return status(id, meta)
            }
            try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
            try JSONEncoder().encode(Meta(fileName: name, size: size)).write(to: dir(id).appendingPathComponent("meta.json"))
            FileManager.default.createFile(atPath: dir(id).appendingPathComponent(name).path, contents: nil)
            return RemoteUploadStatus(id: id, size: size, received: 0)
        }
    }

    package func status(id: String) throws -> RemoteUploadStatus {
        try lock.withLock {
            let id = try checked(id)
            guard let meta = meta(id) else { throw Failure.notFound }
            return status(id, meta)
        }
    }

    /// Appends `data` when `offset` is the amount held.
    package func append(id: String, offset: Int64, data: Data) throws -> RemoteUploadStatus {
        try lock.withLock {
            let id = try checked(id)
            guard let meta = meta(id) else { throw Failure.notFound }
            let held = status(id, meta).received
            guard offset == held else { throw Failure.offset(held: held) }
            guard held + Int64(data.count) <= meta.size else { throw Failure.invalid("the part goes past the end of the file") }
            let handle = try FileHandle(forWritingTo: file(id, meta))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return status(id, meta)
        }
    }

    /// The file when every byte has arrived. Throws `offset` with the amount held when some are missing.
    package func completed(id: String) throws -> URL {
        try lock.withLock {
            let id = try checked(id)
            guard let meta = meta(id) else { throw Failure.notFound }
            let held = status(id, meta).received
            guard held == meta.size else { throw Failure.offset(held: held) }
            return file(id, meta)
        }
    }

    package func discard(id: String) {
        lock.withLock { if let id = try? checked(id) { try? FileManager.default.removeItem(at: dir(id)) } }
    }

    /// Deletes uploads that were never finished and not touched for `age` seconds.
    package func removeStale(olderThan age: TimeInterval, now: Date = Date()) {
        lock.withLock {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: entry) }
            }
        }
    }

    // The id names a folder, so only a UUID is accepted.
    private func checked(_ id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw Failure.invalid("the upload id must be a UUID") }
        return id.uppercased()
    }

    private func dir(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }
    private func file(_ id: String, _ meta: Meta) -> URL { dir(id).appendingPathComponent(meta.fileName) }

    private func meta(_ id: String) -> Meta? {
        (try? Data(contentsOf: dir(id).appendingPathComponent("meta.json"))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
    }

    private func status(_ id: String, _ meta: Meta) -> RemoteUploadStatus {
        let held = (try? file(id, meta).resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        return RemoteUploadStatus(id: id, size: meta.size, received: held)
    }
}
