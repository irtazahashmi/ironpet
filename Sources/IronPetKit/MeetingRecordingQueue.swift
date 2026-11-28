import Foundation

/// The two calls a recording makes. `IronPetClient` is the real one, tests pass a fake.
public protocol MeetingRecordingTransport: Sendable {
    /// Sends chunk `index` of recording `id`. Returning means the Mac holds the chunk, so the phone may delete it. Sending the same
    /// index again is harmless.
    func sendRecordingChunk(id: String, index: Int, data: Data) async throws
    /// Tells the Mac the recording has `count` chunks and is over. Throws a 409 while the Mac is missing some.
    func completeRecording(id: String, count: Int, startedAt: Date) async throws
}

/// What the phone knows about one recording. The audio itself is in the chunk files next to `recording.json`.
public struct PendingRecording: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var startedAt: Date
    /// How many chunks the recording has made so far. Chunk indexes are `0..<chunkCount`.
    public var chunkCount: Int
    /// True once the person pressed Stop (or the recording ended on its own). Only a stopped recording is completed on the Mac.
    public var stopped: Bool
    /// Set when the Mac refused the recording. The chunks are gone by then and the text stays until the person dismisses it.
    public var failure: String?

    public init(id: String, startedAt: Date, chunkCount: Int = 0, stopped: Bool = false, failure: String? = nil) {
        self.id = id; self.startedAt = startedAt; self.chunkCount = chunkCount; self.stopped = stopped; self.failure = failure
    }
}

/// Recordings that have not fully reached the Mac, in a folder: `<folder>/<id>/chunk-000000.wav` and `<folder>/<id>/recording.json`.
/// The recorder writes a chunk as soon as it has it. `drain` sends the chunks in order and deletes each one once the Mac confirmed it,
/// so a chunk file that is still on disk is a chunk the Mac has not confirmed. The recording leaves when it is stopped, every chunk is
/// confirmed and the Mac accepted `complete`.
public final class MeetingRecordingQueue: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(folder: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.now = now
    }

    /// Oldest first, so recordings reach the Mac in the order they were made.
    public var pending: [PendingRecording] {
        lock.withLock { recordingIDs().compactMap { read($0) }.sorted { $0.startedAt < $1.startedAt } }
    }

    public func chunkURL(recording id: String, index: Int) -> URL {
        directory(id).appendingPathComponent(String(format: "chunk-%06d.wav", index))
    }

    /// The indexes of the chunks of `id` that are still on the phone, in order.
    public func unconfirmed(_ id: String) -> [Int] {
        lock.withLock { chunkIndexes(id) }
    }

    /// Starts a recording and returns it.
    @discardableResult
    public func begin() throws -> PendingRecording {
        try lock.withLock {
            let recording = PendingRecording(id: UUID().uuidString, startedAt: now())
            try FileManager.default.createDirectory(at: directory(recording.id), withIntermediateDirectories: true)
            try write(recording)
            return recording
        }
    }

    /// Writes the next chunk of `id`, a complete WAV file. Returns its index. Throws when the file cannot be written, which the
    /// recorder shows as it is.
    @discardableResult
    public func append(_ id: String, wav: Data) throws -> Int {
        try lock.withLock {
            guard var recording = read(id), !recording.stopped else { throw MeetingRecordingError.notRecording }
            let index = recording.chunkCount
            try wav.write(to: chunkURL(recording: id, index: index), options: .atomic)
            recording.chunkCount = index + 1
            try write(recording)
            return index
        }
    }

    /// Marks the recording as over. Its chunks are sent and then completed.
    public func stop(_ id: String) {
        lock.withLock {
            guard var recording = read(id) else { return }
            recording.stopped = true
            try? write(recording)
        }
    }

    /// Removes a recording and its chunks, for a dismissed failure or a recording with no audio.
    public func discard(_ id: String) {
        lock.withLock { try? FileManager.default.removeItem(at: directory(id)) }
    }

    /// Marks the recordings that were running when the app died as stopped, so their chunks go to the Mac as a meeting.
    public func closeInterrupted() {
        lock.withLock {
            for id in recordingIDs() {
                guard var recording = read(id), !recording.stopped else { continue }
                recording.stopped = true
                try? write(recording)
            }
        }
    }

    /// Sends the waiting chunks of every recording, oldest recording first and each recording's chunks in index order. Stops at the
    /// first failure that a later try may fix, because the rest would fail the same way. Returns how many recordings the Mac completed.
    @discardableResult
    public func drain(using transport: any MeetingRecordingTransport) async -> Int {
        var completed = 0
        for recording in pending where recording.failure == nil {
            do {
                if try await send(recording, using: transport) { completed += 1 }
            } catch MeetingUploadFailure.refused(let message) {
                refuse(recording.id, message: message)
            } catch {
                break
            }
        }
        return completed
    }

    /// Sends one recording. True when it was completed and removed.
    private func send(_ recording: PendingRecording, using transport: any MeetingRecordingTransport) async throws -> Bool {
        for index in unconfirmed(recording.id) {
            try Task.checkCancellation()
            guard let data = try? Data(contentsOf: chunkURL(recording: recording.id, index: index)) else { continue }
            do { try await transport.sendRecordingChunk(id: recording.id, index: index, data: data) } catch { throw MeetingUploader.classify(error) }
            confirm(recording.id, index: index)
        }
        // The recording may have grown or stopped while the chunks were going out.
        guard let latest = lock.withLock({ read(recording.id) }), latest.stopped, unconfirmed(latest.id).isEmpty else { return false }
        guard latest.chunkCount > 0 else { discard(latest.id); return false }
        do { try await transport.completeRecording(id: latest.id, count: latest.chunkCount, startedAt: latest.startedAt) } catch { throw MeetingUploader.classify(error) }
        discard(latest.id)
        return true
    }

    /// The Mac holds this chunk, so the phone's copy goes.
    private func confirm(_ id: String, index: Int) {
        lock.withLock { try? FileManager.default.removeItem(at: chunkURL(recording: id, index: index)) }
    }

    private func refuse(_ id: String, message: String) {
        lock.withLock {
            guard var recording = read(id) else { return }
            for index in chunkIndexes(id) { try? FileManager.default.removeItem(at: chunkURL(recording: id, index: index)) }
            recording.failure = message
            recording.stopped = true
            try? write(recording)
        }
    }

    // MARK: Files

    private func directory(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }
    private func metaURL(_ id: String) -> URL { directory(id).appendingPathComponent("recording.json") }

    private func recordingIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }
    }

    private func chunkIndexes(_ id: String) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(id).path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix("chunk-"), name.hasSuffix(".wav") else { return nil }
            return Int(name.dropFirst(6).dropLast(4))
        }.sorted()
    }

    private func read(_ id: String) -> PendingRecording? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        return try? Self.decoder.decode(PendingRecording.self, from: data)
    }

    private func write(_ recording: PendingRecording) throws {
        try Self.encoder.encode(recording).write(to: metaURL(recording.id), options: .atomic)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

public enum MeetingRecordingError: Error, Equatable, LocalizedError {
    case notRecording

    public var errorDescription: String? { "There is no recording to add audio to." }
}

/// How the phone builds a chunk: 16 kHz mono 16-bit samples in a WAV file, `chunkSeconds` of audio each.
public enum MeetingRecordingFormat {
    public static let sampleRate = 16_000
    public static let chunkSeconds = 30
    /// PCM bytes in one full chunk.
    public static let chunkBytes = chunkSeconds * sampleRate * 2

    /// A complete WAV file around 16-bit little-endian mono PCM.
    public static func wav(pcm: Data) -> Data {
        var data = Data(capacity: 44 + pcm.count)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
