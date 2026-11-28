import Foundation
#if canImport(Combine)
import Combine
#endif

/// A past (or running) meeting: one folder under `~/.ironpet/meetings`.
package struct MeetingRecord: Identifiable, Equatable {
    package init(folder: URL, date: Date, preview: String, hasSummary: Bool, hasTranscript: Bool, hasAudio: Bool = false, isRoom: Bool = false, title: String? = nil) {
        self.folder = folder
        self.date = date
        self.preview = preview
        self.hasSummary = hasSummary
        self.hasTranscript = hasTranscript
        self.hasAudio = hasAudio
        self.isRoom = isRoom
        self.title = title
    }

    package let folder: URL
    package let date: Date
    /// The first line of the summary that is not a heading, or of the transcript when there is no summary yet.
    package let preview: String
    package let hasSummary: Bool
    package let hasTranscript: Bool
    /// The folder still has `mic-NNN.wav` or `them-NNN.wav` chunks, so it can be transcribed again.
    package var hasAudio = false
    /// Recorded in a room: the microphone alone, with the voices told apart by speaker recognition.
    package var isRoom = false
    /// The title the user accepted or typed, from `title.txt`. Nil until then.
    package var title: String? = nil

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
    /// Turns an audio file into a meeting in this library.
    package lazy var importer = MeetingImporter(library: self, root: root)

    package init(root: URL = Paths.meetings) {
        self.root = root
    }

    /// The folder for a meeting that began at `date`: `yyyy-MM-dd-HHmm`, with `-2`, `-3` … when that minute is taken.
    package nonisolated static func newFolder(for date: Date, in root: URL) -> URL {
        let base = MeetingTranscript.folderName(date)
        var url = root.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return url
    }

    /// True once `reload()` has read the folder. Until then `meetings` is empty because nobody asked, not because there are none.
    package private(set) var isLoaded = false

    /// Reads the folder the first time a caller needs the list, such as the phone's `GET /v1/meetings` right after the app starts.
    package func loadIfNeeded() {
        if !isLoaded { reload() }
    }

    package func reload() {
        isLoaded = true
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

    // MARK: Suggestions

    package enum SuggestionError: LocalizedError, Equatable {
        case noMeeting, notSuggested, emptyName, failed
        package var errorDescription: String? {
            switch self {
            case .noMeeting: return "No such meeting."
            case .notSuggested: return "This meeting has no such speaker."
            case .emptyName: return "Type a name."
            case .failed: return "The files could not be updated."
            }
        }
    }

    /// The title and speaker names proposed for a meeting and not yet accepted.
    package func suggestions(for id: String) -> MeetingSuggestions {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return MeetingSuggestions() }
        return MeetingSuggestions.load(meeting.folder)
    }

    /// Stores the title the user accepted or edited. An empty title clears it. The suggested title is used up.
    package func acceptTitle(_ id: String, title: String) throws {
        guard let meeting = meetings.first(where: { $0.id == id }) else { throw SuggestionError.noMeeting }
        do { try MeetingSuggestions.setTitle(title, in: meeting.folder) } catch { throw SuggestionError.failed }
        var left = MeetingSuggestions.load(meeting.folder)
        left.title = nil
        left.save(to: meeting.folder)
        reload()
    }

    /// Names a voice of a saved meeting the way naming it right after the meeting does: every line and the summary show
    /// the name, and the voice goes into the voice store when it has enough speech and speaker recognition is on.
    package func acceptSpeaker(_ id: String, label: String, name: String) throws {
        guard let meeting = meetings.first(where: { $0.id == id }) else { throw SuggestionError.noMeeting }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SuggestionError.emptyName }
        let transcript = (try? String(contentsOf: meeting.transcriptURL, encoding: .utf8)) ?? ""
        guard SpeakerRename.hasSpeaker(label, in: transcript) else { throw SuggestionError.notSuggested }
        guard SpeakerRename.renameInFolder(meeting.folder, from: label, to: name) else { throw SuggestionError.failed }
        if let voice = regenerator.speakerVoices[id]?[label] {
            if regenerator.recogniseSpeakers(), !voice.mixed {
                _ = regenerator.voiceStore.enroll(name: name, embedding: voice.centroid, seconds: voice.seconds, meetingConfirmed: true)
            }
            regenerator.speakerVoices[id]?[label] = nil
        }
        var left = MeetingSuggestions.load(meeting.folder)
        left.speakers[label] = nil
        left.save(to: meeting.folder)
        reload()
    }

    /// Drops what was proposed for a meeting, for "No thanks".
    package func dismissSuggestions(_ id: String) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        MeetingSuggestions().save(to: meeting.folder)
        regenerator.speakerVoices[id] = nil
        reload()
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
        // A room meeting has `room-NNN.wav` chunks, and its transcript header names the app "Room".
        let room = files.contains { MeetingFolderScan.chunkName($0)?.track == .room }
            || (hasTranscript && MeetingFolderScan.appName(fromTranscript: head(of: transcript)) == AudioApps.roomMeetingName)
        return MeetingRecord(folder: folder, date: date, preview: preview, hasSummary: hasSummary, hasTranscript: hasTranscript,
                             hasAudio: files.contains { MeetingFolderScan.chunkName($0) != nil }, isRoom: room,
                             title: MeetingSuggestions.title(in: folder))
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
