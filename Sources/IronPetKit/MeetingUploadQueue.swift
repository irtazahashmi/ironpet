import Foundation

/// One audio file that waits on the phone for the Mac.
public struct PendingUpload: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var fileName: String
    public var size: Int64
    public var queuedAt: Date
    /// Set when the Mac refused the file. The file is gone by then and the text stays until the person dismisses it.
    public var failure: String?

    public init(id: String, fileName: String, size: Int64, queuedAt: Date, failure: String? = nil) {
        self.id = id; self.fileName = fileName; self.size = size; self.queuedAt = queuedAt; self.failure = failure
    }
}

/// The audio files that have not reached the Mac, in a folder. The app and the share extension both write to it, so the folder is in the
/// app group. Each file is `<folder>/<id>/<file name>`, and `queue.json` lists them. A file leaves only when the Mac confirmed the whole of it
/// or refused it.
public final class MeetingUploadQueue: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(folder: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.now = now
    }

    private var listURL: URL { folder.appendingPathComponent("queue.json") }

    public func fileURL(for upload: PendingUpload) -> URL {
        folder.appendingPathComponent(upload.id, isDirectory: true).appendingPathComponent(upload.fileName)
    }

    public var pending: [PendingUpload] { lock.withLock { read() } }

    /// Copies `source` into the queue. Throws the refusal text for a file that is not m4a, mp3 or wav or is over 1 GB, and queues nothing.
    @discardableResult
    public func enqueue(copying source: URL, named name: String? = nil) throws -> PendingUpload {
        let fileName = ((name ?? source.lastPathComponent) as NSString).lastPathComponent
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        if let refusal = MeetingUploadLimits.refusal(fileName: fileName, size: size) { throw MeetingUploadRefused(message: refusal) }
        return try lock.withLock {
            let id = UUID().uuidString
            let entry = PendingUpload(id: id, fileName: fileName, size: size ?? 0, queuedAt: now())
            let destination = fileURL(for: entry)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
                throw MeetingUploadRefused(message: MeetingUploadLimits.unreadable(fileName))
            }
            write(read() + [entry])
            return entry
        }
    }

    /// Removes the file and the entry. Called once the Mac has the whole file.
    public func confirm(_ id: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(id, isDirectory: true))
            write(read().filter { $0.id != id })
        }
    }

    /// The Mac refused the file: delete it and keep the reason in the list.
    public func reject(_ id: String, message: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(id, isDirectory: true))
            write(read().map { var entry = $0; if entry.id == id { entry.failure = message }; return entry })
        }
    }

    public func dismiss(_ id: String) { confirm(id) }

    /// Sends the waiting files one after the other. Stops at the first one the Mac cannot be reached for, because the rest would fail
    /// the same way. Returns how many the Mac confirmed.
    @discardableResult
    public func drain(using transport: any MeetingUploadTransport, uploader: MeetingUploader = MeetingUploader()) async -> Int {
        var confirmed = 0
        for entry in pending where entry.failure == nil {
            guard FileManager.default.fileExists(atPath: fileURL(for: entry).path) else {
                reject(entry.id, message: MeetingUploadLimits.unreadable(entry.fileName))
                continue
            }
            do {
                try await uploader.upload(file: fileURL(for: entry), id: entry.id, fileName: entry.fileName, transport: transport)
                confirm(entry.id)
                confirmed += 1
            } catch MeetingUploadFailure.refused(let message) {
                reject(entry.id, message: message)
            } catch {
                break
            }
        }
        return confirmed
    }

    private func read() -> [PendingUpload] {
        guard let data = try? Data(contentsOf: listURL) else { return [] }
        return (try? Self.decoder.decode([PendingUpload].self, from: data)) ?? []
    }

    private func write(_ entries: [PendingUpload]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if entries.isEmpty { try? FileManager.default.removeItem(at: listURL); return }
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: listURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// Why a file was not queued. The text is shown as it is.
public struct MeetingUploadRefused: Error, Equatable, LocalizedError {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What the share extension does with what the share sheet hands it. The extension loads each attachment to a file and passes the
/// files here, so the part that decides what is queued is the same code the tests run.
public enum ShareHandoff {
    /// The name a shared file keeps. The system hands over some files without an extension, so one is added from the type.
    public static func fileName(_ name: String, typeIdentifiers: [String]) -> String {
        let name = (name as NSString).lastPathComponent
        if MeetingUploadLimits.extensions.contains((name as NSString).pathExtension.lowercased()) { return name }
        for type in typeIdentifiers {
            switch type {
            case "public.mpeg-4-audio", "com.apple.m4a-audio": return (name as NSString).deletingPathExtension + ".m4a"
            case "public.mp3": return (name as NSString).deletingPathExtension + ".mp3"
            case "com.microsoft.waveform-audio", "public.wav": return (name as NSString).deletingPathExtension + ".wav"
            default: continue
            }
        }
        return name
    }

    /// Queues every file. Returns how many were queued and the refusal of each one that was not.
    public static func accept(_ files: [(url: URL, name: String, typeIdentifiers: [String])], into queue: MeetingUploadQueue) -> (queued: Int, refusals: [String]) {
        var queued = 0
        var refusals: [String] = []
        for file in files {
            do {
                try queue.enqueue(copying: file.url, named: fileName(file.name, typeIdentifiers: file.typeIdentifiers))
                queued += 1
            } catch { refusals.append((error as? MeetingUploadRefused)?.message ?? error.localizedDescription) }
        }
        return (queued, refusals)
    }
}
