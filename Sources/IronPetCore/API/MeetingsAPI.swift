import Foundation
import IronPetKit
#if canImport(Combine)
import Combine
#endif

/// A meeting as a client that cannot read the Mac's folders sees it.
package struct MeetingInfo: Codable, Equatable, Identifiable {
    package init(id: String, date: Date, preview: String, hasSummary: Bool, hasTranscript: Bool, hasAudio: Bool, active: Bool) {
        self.id = id
        self.date = date
        self.preview = preview
        self.hasSummary = hasSummary
        self.hasTranscript = hasTranscript
        self.hasAudio = hasAudio
        self.active = active
    }

    package var id: String
    package var date: Date
    /// The first line of the summary that is not a heading, or of the transcript.
    package var preview: String
    package var hasSummary: Bool
    package var hasTranscript: Bool
    /// The audio chunks are still there, so the transcript can be made again.
    package var hasAudio: Bool
    /// The meeting is being recorded or summarized now.
    package var active: Bool
}

package enum MeetingText: String, Codable {
    case summary, transcript
}

package struct MeetingTextRequest: Codable, Equatable {
    package init(id: String, kind: MeetingText) {
        self.id = id
        self.kind = kind
    }

    package var id: String
    package var kind: MeetingText
}

package enum MeetingRegeneration: String, Codable {
    /// Transcribe every saved chunk again, then summarize.
    case full
    /// Summarize the transcript that is already there, for example after a speaker was named.
    case summaryOnly
}

package struct RegenerateMeetingRequest: Codable, Equatable {
    package init(id: String, mode: MeetingRegeneration = .full) {
        self.id = id
        self.mode = mode
    }

    package var id: String
    package var mode: MeetingRegeneration = .full
}

package struct NameSpeakerRequest: Codable, Equatable {
    package init(speaker: Int, name: String) {
        self.speaker = speaker
        self.name = name
    }

    package var speaker: Int
    package var name: String
}

package struct DismissSpeakerRequest: Codable, Equatable {
    package init(speaker: Int, mixed: Bool = false) {
        self.speaker = speaker
        self.mixed = mixed
    }

    package var speaker: Int
    /// Two people share this voice, so it cannot be named.
    package var mixed = false
}

package struct MeetingStatus: Codable, Equatable {
    package init(
        phase: String,
        folder: String? = nil,
        appName: String,
        startedAt: Date? = nil,
        chunksDone: Int,
        chunksWaiting: Int,
        chunksFailed: Int,
        speakersToName: Int
    ) {
        self.phase = phase
        self.folder = folder
        self.appName = appName
        self.startedAt = startedAt
        self.chunksDone = chunksDone
        self.chunksWaiting = chunksWaiting
        self.chunksFailed = chunksFailed
        self.speakersToName = speakersToName
    }

    /// `idle`, `choosing`, `recording`, `finishing`, `summarizing` or `done`.
    package var phase: String
    package var folder: String?
    package var appName: String
    package var startedAt: Date?
    /// Chunks of the open recording that are transcribed, waiting and failed.
    package var chunksDone: Int
    package var chunksWaiting: Int
    package var chunksFailed: Int
    /// Voices of the last meeting that still need a name.
    package var speakersToName: Int
}

/// Meetings and their transcripts: list, summary and transcript text, regenerate, ask, delete, stop recording, name a speaker.
///
/// This is an `ObservableObject` so the transcripts page and the recording panel redraw as meetings change.
@MainActor
package final class MeetingsAPI {
    /// Fires before the recording, the library or a regeneration change.
    package let changes = ChangeSignal()
    private let recorder: MeetingRecorder
    private let library: MeetingLibrary
    private var forwarding: [ChangeToken] = []

    /// Opens the chat with these files attached. The app owner sets it.
    package var askHandler: (([URL]) -> Void)?

    package init(recorder: MeetingRecorder, library: MeetingLibrary) {
        self.recorder = recorder
        self.library = library
        forwarding = [
            recorder.changes.observe { [weak self] in self?.changes.send() },
            library.changes.observe { [weak self] in self?.changes.send() },
            library.regenerator.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    // MARK: Library

    /// The meetings for the transcripts page, newest first.
    package var meetings: [MeetingRecord] { library.meetings }

    package func reload() { library.reload() }

    package func list() -> [MeetingInfo] {
        library.loadIfNeeded()
        let active = activeFolder
        return library.meetings.map { MeetingInfo(id: $0.id, date: $0.date, preview: $0.preview, hasSummary: $0.hasSummary,
                                                  hasTranscript: $0.hasTranscript, hasAudio: $0.hasAudio, active: $0.folder == active) }
    }

    package func get(_ id: String) throws -> MeetingInfo {
        guard let info = list().first(where: { $0.id == id }) else { throw APIError.notFound("no meeting with id \"\(id)\"") }
        return info
    }

    /// The summary or transcript text. Nil when the meeting has no such file yet. The read runs off the main thread.
    package func text(_ request: MeetingTextRequest) async throws -> String? {
        let record = try record(request.id)
        let url = request.kind == .summary ? record.summaryURL : record.transcriptURL
        return await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
    }

    /// Moves the meeting's folder to the Trash. The meeting being recorded or rebuilt cannot be deleted.
    package func delete(_ id: String) throws {
        let record = try record(id)
        guard record.folder != activeFolder, regenerationID != id else { throw APIError.conflict("this meeting is still being recorded or rebuilt") }
        do { try library.delete(id) } catch { throw APIError.failed("Could not move it to the Trash: \(error.localizedDescription)") }
    }

    /// Opens the chat with the meeting's transcript and summary attached.
    package func ask(_ id: String) throws {
        let files = try record(id).chatFiles
        guard !files.isEmpty else { throw APIError.invalid("this meeting has no transcript or summary yet") }
        guard let askHandler else { throw APIError.unavailable("the chat is not available") }
        askHandler(files)
    }

    // MARK: Regeneration

    package var regenerationID: String? { library.regenerator.activeID }
    package var regenerationProgress: RegenerationProgress? { library.regenerator.progress }
    package var regenerationErrors: [String: String] { library.regenerator.errors }
    /// Counts finished runs, so a view knows when the files on disk changed.
    package var regenerationsCompleted: Int { library.regenerator.completed }

    /// Why a meeting cannot be rebuilt now, or nil when it can.
    package func regenerationBlocked(_ id: String, mode: MeetingRegeneration = .full) -> String? {
        guard let record = try? record(id) else { return "No such meeting." }
        return library.regenerator.unavailableReason(for: record, activeFolder: activeFolder, requiresAudio: mode == .full)
    }

    /// Makes a new transcript and summary. The old files stay as `.prev.md`.
    package func regenerate(_ request: RegenerateMeetingRequest) async throws {
        let record = try record(request.id)
        let ok = await library.regenerator.regenerate(record, mode: request.mode == .full ? .full : .summaryOnly, activeFolder: activeFolder)
        if !ok { throw APIError.failed(library.regenerator.errors[record.id] ?? "The meeting could not be rebuilt.") }
    }

    // MARK: Recording

    package var status: MeetingStatus {
        let counts = recorder.counts
        return MeetingStatus(phase: recorder.phase.rawValue, folder: recorder.folder?.path, appName: recorder.appName,
                             startedAt: recorder.startedAt, chunksDone: counts.done, chunksWaiting: counts.waiting,
                             chunksFailed: counts.failed, speakersToName: recorder.speakersToName.count)
    }

    /// The folder of the meeting being recorded or summarized, if any.
    package var activeFolder: URL? {
        [.recording, .finishing, .summarizing].contains(recorder.phase) ? recorder.folder : nil
    }

    /// Ends the recording. The transcript and summary follow.
    package func stopRecording() throws {
        guard recorder.isRecording else { throw APIError.conflict("no meeting is being recorded") }
        do { try recorder.stop() } catch { throw APIError.unavailable(error.localizedDescription) }
    }

    // MARK: Speakers

    package func nameSpeaker(_ request: NameSpeakerRequest) throws {
        guard recorder.speakersToName.contains(where: { $0.id == request.speaker }) || recorder.speakerTable.speaker(request.speaker) != nil else {
            throw APIError.notFound("no speaker \(request.speaker) in the last meeting")
        }
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.invalid("the name is empty") }
        recorder.nameSpeaker(request.speaker, as: request.name)
    }

    package func dismissSpeaker(_ request: DismissSpeakerRequest) throws {
        guard recorder.speakerTable.speaker(request.speaker) != nil else { throw APIError.notFound("no speaker \(request.speaker) in the last meeting") }
        recorder.dismissSpeaker(request.speaker, mixed: request.mixed)
    }

    // MARK: Stored voices

    /// The voices ironpet recognises in later meetings, each with how much speech it holds.
    package func voiceprints() -> [StoredVoice] { recorder.voiceStore.voices() }

    /// Whether the encrypted voice file exists, even when it holds no voice ironpet can read.
    package var hasVoiceFile: Bool { recorder.voiceStore.hasFile }

    package func forgetVoice(_ id: String) throws {
        guard recorder.voiceStore.voices().contains(where: { $0.id == id }) else { throw APIError.notFound("no stored voice with id \"\(id)\"") }
        recorder.voiceStore.forget(id: id)
    }

    /// Renames a stored voice and the speaker in its past meetings. The voiceprint itself does not change.
    /// Throws `invalid` for an empty name or a name another stored voice has, and changes nothing then.
    package func renameVoice(_ id: String, to name: String) throws {
        let old: String
        do {
            old = try recorder.voiceStore.rename(id: id, to: name)
        } catch let error as VoiceStore.RenameError {
            switch error {
            case .emptyName: throw APIError.invalid("Type a name.")
            case .nameTaken: throw APIError.invalid("Another voice already has that name.")
            case .notFound: throw APIError.notFound("no stored voice with id \"\(id)\"")
            case .unavailable: throw APIError.unavailable("The voice file cannot be read or written.")
            }
        }
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard old != new else { return }
        let outcome = library.renameSpeaker(from: old, to: new, skipping: activeFolder.map { [$0] } ?? [])
        if outcome.failed > 0 {
            throw APIError.failed("The voice was renamed, but \(outcome.failed) past meeting(s) could not be updated.")
        }
    }

    package func forgetAllVoices() { recorder.voiceStore.forgetAll() }

    // MARK: The recording panel

    package var phase: MeetingPhase { recorder.phase }
    package var apps: [AudioApp] { recorder.apps }
    package var choice: AudioChoice { get { recorder.choice } set { recorder.choice = newValue } }
    package var notice: String? { recorder.notice }
    package var appName: String { recorder.appName }
    package var startedAt: Date? { recorder.startedAt }
    /// The name of the folder the open meeting is saved in.
    package var folderLabel: String { recorder.folder?.lastPathComponent ?? "" }
    package var myLevels: LevelBuffer { recorder.myLevels }
    package var theirLevels: LevelBuffer { recorder.theirLevels }
    package var counts: (done: Int, waiting: Int, failed: Int) { recorder.counts }
    package var recentLines: [MeetingLine] { recorder.recentLines }
    package var summaryState: MeetingSummaryState { recorder.summary }
    /// Starts a recording. Where nothing can record, it does nothing.
    package func start() { try? recorder.start() }
    package func dismiss() { recorder.dismiss() }
    package func confirmDiscard() { recorder.confirmDiscard() }
    package func retryFailed() { recorder.retryFailed() }
    package func openTranscript() { recorder.openTranscript() }
    package func openSummary() { recorder.openSummary() }
    package func openInChat() { recorder.openInChat() }
    /// Opens Settings on the Meetings page, where voices are named.
    package func labelSpeakers() { recorder.onLabelSpeakers?() }

    // Naming the voices of the last meeting.
    package var hasSpeakersToName: Bool { recorder.hasSpeakersToName }
    package var speakersToName: [MeetingSpeaker] { recorder.speakersToName }
    package var storedNames: [String] { recorder.storedNames }
    package func knownNames(stored: [String]) -> [String] { recorder.knownNames(stored: stored) }
    package func sampleLine(for id: Int) -> String? { recorder.sampleLine(for: id) }
    package var canRegenerateSummary: Bool { recorder.canRegenerateSummary }
    package var regeneratingSummary: Bool { recorder.regeneratingSummary }
    package func regenerateSummary() { recorder.regenerateSummary() }

    private func record(_ id: String) throws -> MeetingRecord {
        library.loadIfNeeded()
        guard let record = library.meetings.first(where: { $0.id == id }) else { throw APIError.notFound("no meeting with id \"\(id)\"") }
        return record
    }
}

#if canImport(Combine)

extension MeetingsAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
