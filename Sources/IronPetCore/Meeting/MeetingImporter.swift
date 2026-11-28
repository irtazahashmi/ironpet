import Foundation
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
    package nonisolated static let maxBytes: Int64 = 1_073_741_824
    package nonisolated static let maxSeconds: Double = 4 * 3600
    package nonisolated static let extensions = ["m4a", "mp3", "wav"]
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
        try validate(file)
        let started = date ?? creationDate(file) ?? now()
        let folder = MeetingLibrary.newFolder(for: started, in: root)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw fail("Could not create \(folder.path): \(error.localizedDescription)")
        }
        stage = "Reading audio"
        do {
            let written = try await Self.split(file, into: folder, with: transcoder, chunker: makeChunker())
            guard written > 0 else {
                throw MeetingImportError(message: "\(file.lastPathComponent) could not be decoded as audio, so no meeting was created.")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw fail((error as? MeetingImportError)?.message ?? "Could not read \(file.lastPathComponent): \(error.localizedDescription)")
        }
        library.reload()
        guard let record = library.meetings.first(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) else {
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
        let ext = file.pathExtension.lowercased()
        guard Self.extensions.contains(ext) else {
            throw fail("ironpet imports m4a, mp3 and wav files. \(file.lastPathComponent) is not one of them.")
        }
        guard let size = fileSize(file) else { throw fail("Could not read \(file.lastPathComponent).") }
        guard size <= Self.maxBytes else {
            throw fail("\(file.lastPathComponent) is larger than the 1 GB limit for an imported file.")
        }
        guard let seconds = transcoder.duration(of: file) else {
            throw fail("\(file.lastPathComponent) could not be read as audio.")
        }
        guard seconds <= Self.maxSeconds else {
            throw fail("\(file.lastPathComponent) is longer than the 4 hour limit for an imported file.")
        }
    }

    private func fail(_ message: String) -> MeetingImportError {
        lastError = message
        return MeetingImportError(message: message)
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
