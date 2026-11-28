import Foundation
import IronPetKit
#if canImport(Combine)
import Combine
#endif

/// Why an audio file was not imported. The text names the limit, because the user sees it as is.
package struct MeetingImportError: LocalizedError, Equatable {
    package init(message: String) {
        self.message = message
    }

    package let message: String
    package var errorDescription: String? { message }
}

/// Turns an audio file into a meeting. It decodes the file to 16 kHz mono with `AudioTranscoder`, cuts it into
/// `room-NNN.wav` chunks with `Chunker` and hands the folder to `MeetingRegenerator`, the code that also rebuilds a
/// room recording. The transcript, speakers and summary therefore come from the pipeline a recording uses.
@MainActor
package final class MeetingImporter {
    package nonisolated static let maxBytes = MeetingUploadLimits.maxBytes
    package nonisolated static let maxSeconds = MeetingUploadLimits.maxSeconds
    package nonisolated static let extensions = MeetingUploadLimits.extensions
    /// What the transcript header calls the app.
    package nonisolated static let appName = "Imported audio"

    package init(library: MeetingLibrary, root: URL) {
        self.library = library
        self.root = root
    }

    /// Fires before `isImporting`, `stage` or `lastError` change.
    package let changes = ChangeSignal()
    package private(set) var isImporting = false { willSet { changes.send() } }
    /// What the import is doing before the regenerator takes over, or nil.
    package private(set) var stage: String? { willSet { changes.send() } }
    /// Why the last import failed, until the next one starts.
    package private(set) var lastError: String? { willSet { changes.send() } }

    /// Decodes audio. `AppDelegate` sets the Mac one.
    package var transcoder: AudioTranscoder = UnsupportedAudioTranscoder()
    /// The size of a file in bytes. Tests replace it.
    package var fileSize: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
    /// When the file was made, or nil when the file system does not say. Tests replace it.
    package var creationDate: @Sendable (URL) -> Date? = { url in
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
    package var now: () -> Date = { Date() }
    /// Tests pass shorter chunks.
    package var makeChunker: @Sendable () -> Chunker = { Chunker() }

    private unowned let library: MeetingLibrary
    private let root: URL

    /// Imports `file` and returns the meeting. Nothing is created for a file that is refused. When the file was
    /// saved but the transcript or summary failed, the meeting stays in the list, ready for Regenerate, and this throws.
    /// `date` is the meeting's date; without it the file's creation date, and without that the time of the import.
    @discardableResult
    package func importAudio(file: URL, date: Date? = nil) async throws -> MeetingRecord {
        try await build(label: file.lastPathComponent, date: { date ?? self.creationDate(file) ?? self.now() }, check: { try self.validate(file) }) { folder in
            try await Self.split(file, into: folder, with: self.transcoder, chunker: self.makeChunker())
        }
    }

    /// Turns the chunks of a room recording made on the phone into a meeting. `chunks` are WAV files in the order they were recorded,
    /// and `date` is when the recording started. They go through the same chunker and regenerator as an imported file.
    @discardableResult
    package func importRecording(chunks: [URL], date: Date) async throws -> MeetingRecord {
        let seconds = chunks.reduce(0.0) { $0 + (((try? Data(contentsOf: $1)).flatMap { WAV.duration(of: $0) }) ?? 0) }
        return try await build(label: "The recording", date: { date }, check: {
            guard seconds <= Self.maxSeconds else { throw self.fail(MeetingUploadLimits.tooLong("The recording")) }
        }) { folder in
            try await Self.split(chunks: chunks, into: folder, chunker: self.makeChunker())
        }
    }

    /// The steps both imports share: check, create the folder, write `room-NNN.wav` through `write`, then rebuild.
    private func build(label: String, date: () -> Date, check: () throws -> Void, write: (URL) async throws -> Int) async throws -> MeetingRecord {
        guard !isImporting else { throw fail("Another import is running. Try again when it is done.") }
        if let activeID = library.regenerator.activeID, !activeID.isEmpty {
            throw fail("Another meeting is being rebuilt. Try again when it is done.")
        }
        lastError = nil
        isImporting = true
        defer {
            isImporting = false
            stage = nil
        }
        stage = "Checking the file"
        try check()
        let started = date()
        let folder = MeetingLibrary.newFolder(for: started, in: root)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw fail("Could not create \(folder.path): \(error.localizedDescription)")
        }
        stage = "Reading audio"
        do {
            let written = try await write(folder)
            guard written > 0 else {
                throw MeetingImportError(message: "\(label) could not be decoded as audio, so no meeting was created.")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw fail((error as? MeetingImportError)?.message ?? "Could not read \(label): \(error.localizedDescription)")
        }
        library.reload()
        guard let record = library.meetings.first(where: { $0.id == folder.lastPathComponent }) else {
            throw fail("The meeting folder was written but is not in the list.")
        }
        stage = nil
        let ok = await library.regenerator.regenerate(record, mode: .full, appName: Self.appName)
        library.reload()
        if !ok {
            let reason = library.regenerator.errors[record.id] ?? "The meeting could not be built."
            throw fail("The audio was saved as a meeting, but it could not be built. \(reason) Use Regenerate to try again.")
        }
        return library.meetings.first(where: { $0.id == record.id }) ?? record
    }

    /// Refuses a file ironpet will not import. Checks the extension, the size and the length, in that order, so a
    /// large file of the wrong kind is refused for its kind.
    package func validate(_ file: URL) throws {
        let name = file.lastPathComponent
        if let refusal = MeetingUploadLimits.refusal(fileName: name, size: fileSize(file)) { throw fail(refusal) }
        guard let seconds = transcoder.duration(of: file) else { throw fail(MeetingUploadLimits.notAudio(name)) }
        guard seconds <= Self.maxSeconds else { throw fail(MeetingUploadLimits.tooLong(name)) }
    }

    private func fail(_ message: String) -> MeetingImportError {
        lastError = message
        return MeetingImportError(message: message)
    }

    /// Reads the phone's WAV chunks off the main thread and cuts them into `room-NNN.wav`. Returns how many it wrote.
    private nonisolated static func split(chunks: [URL], into folder: URL, chunker start: Chunker) async throws -> Int {
        try await Task.detached {
            var chunker = start
            var index = 0
            func write(_ samples: [Int16]) throws {
                index += 1
                let url = folder.appendingPathComponent(String(format: "%@-%03d.wav", MeetingTrack.room.filePrefix, index))
                try WAV.encode(samples).write(to: url, options: .atomic)
            }
            for url in chunks {
                let samples = WAV.samples(of: try Data(contentsOf: url))
                guard !samples.isEmpty else { return 0 }
                for closed in chunker.push(samples) { try write(closed) }
            }
            if let rest = chunker.flush() { try write(rest) }
            return index
        }.value
    }

    /// Decodes off the main thread and writes the chunks. Returns how many chunks it wrote.
    private nonisolated static func split(_ file: URL, into folder: URL, with transcoder: AudioTranscoder, chunker start: Chunker) async throws -> Int {
        try await Task.detached {
            var chunker = start
            var index = 0
            func write(_ samples: [Int16]) throws {
                index += 1
                let url = folder.appendingPathComponent(String(format: "%@-%03d.wav", MeetingTrack.room.filePrefix, index))
                try WAV.encode(samples).write(to: url, options: .atomic)
            }
            let decoded = try transcoder.stream(from: file) { block in
                for closed in chunker.push(block) { try write(closed) }
            }
            guard decoded else { return 0 }
            if let rest = chunker.flush() { try write(rest) }
            return index
        }.value
    }
}

#if canImport(Combine)

extension MeetingImporter: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
