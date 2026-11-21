import Foundation
#if canImport(Combine)
import Combine
#endif

/// A past (or running) meeting: one folder under `~/.ironpet/meetings`.
package struct MeetingRecord: Identifiable, Equatable {
    package init(folder: URL, date: Date, preview: String, hasSummary: Bool, hasTranscript: Bool, hasAudio: Bool = false) {
        self.folder = folder
        self.date = date
        self.preview = preview
        self.hasSummary = hasSummary
        self.hasTranscript = hasTranscript
        self.hasAudio = hasAudio
    }

    package let folder: URL
    package let date: Date
    /// The first line of the summary that is not a heading, or of the transcript when there is no summary yet.
    package let preview: String
    package let hasSummary: Bool
    package let hasTranscript: Bool
    /// The folder still has `mic-NNN.wav` or `them-NNN.wav` chunks, so it can be transcribed again.
    package var hasAudio = false

    package var id: String { folder.lastPathComponent }
    package var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
    package var summaryURL: URL { folder.appendingPathComponent("summary.md") }
    /// What "Ask Ghost about this meeting" attaches, the same files the meeting bubble sends.
    package var chatFiles: [URL] { [transcriptURL, summaryURL].filter { FileManager.default.fileExists(atPath: $0.path) } }
}

/// The Transcripts section's list. Reads only the folder names and the start of each summary; the full texts are read
/// when a meeting is opened, off the main thread.
@MainActor
package final class MeetingLibrary {
    /// Fires before `meetings` changes.
    package let changes = ChangeSignal()
    package private(set) var meetings: [MeetingRecord] = [] {
        willSet { changes.send() }
        didSet { if meetings != oldValue { events?.publish(.meetingsChanged) } }
    }
    /// Where `meetings.changed` is published for API clients.
    package weak var events: APIEventBus?
    /// Rebuilds a meeting's transcript and summary. Lives here so the list and the work on it share one place.
    package let regenerator = MeetingRegenerator()
    /// Called with the folder after a meeting went to the Trash, so its text leaves the memory index.
    package var onDeleted: ((URL) -> Void)?
    private let root: URL

    package init(root: URL = Paths.meetings) {
        self.root = root
    }

    package func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        meetings = folders.compactMap(Self.record).sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Writes `new` over `old` in the saved meetings that have a line from that speaker. The caller names the folder
    /// being recorded, which the recorder still writes itself.
    package func renameSpeaker(from old: String, to new: String, skipping: Set<URL> = []) -> SpeakerRename.Outcome {
        let outcome = SpeakerRename.apply(root: root, from: old, to: new, skipping: skipping)
        reload()
        return outcome
    }

    /// Moves the folder to the Trash rather than deleting it, so a wrong click can be undone in Finder.
    package func delete(_ id: String) throws {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        #if canImport(Darwin)
        try FileManager.default.trashItem(at: meeting.folder, resultingItemURL: nil)
        #else
        try FileManager.default.removeItem(at: meeting.folder)
        #endif
        onDeleted?(meeting.folder)
        reload()
    }

    package static func record(_ folder: URL) -> MeetingRecord? {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let date = date(folderName: folder.lastPathComponent) else { return nil }
        let summary = folder.appendingPathComponent("summary.md"), transcript = folder.appendingPathComponent("transcript.md")
        let hasSummary = FileManager.default.fileExists(atPath: summary.path)
        let hasTranscript = FileManager.default.fileExists(atPath: transcript.path)
        let preview = (hasSummary ? head(of: summary) : hasTranscript ? head(of: transcript) : nil).flatMap(firstLine) ?? ""
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return MeetingRecord(folder: folder, date: date, preview: preview, hasSummary: hasSummary, hasTranscript: hasTranscript,
                             hasAudio: files.contains { MeetingFolderScan.chunkName($0) != nil })
    }

    /// `yyyy-MM-dd-HHmm`, with the `-2`, `-3` … suffix a second meeting in the same minute gets.
    package nonisolated static func date(folderName: String) -> Date? {
        let parts = folderName.split(separator: "-")
        guard parts.count == 4 || parts.count == 5, parts.dropFirst(4).allSatisfy({ Int($0) != nil }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.date(from: parts.prefix(4).joined(separator: "-"))
    }

    package static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" }
            .map { line in
                var line = line
                for marker in ["- ", "* ", "> "] where line.hasPrefix(marker) { line.removeFirst(marker.count) }
                return line.replacingOccurrences(of: "**", with: "")
            }
    }

    /// The first few KB, enough for a preview line, so a long transcript is not read for the list.
    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4096)).flatMap { String(decoding: $0, as: UTF8.self) }
    }
}

#if canImport(Combine)

extension MeetingLibrary: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
