import Foundation
#if canImport(Combine)
import Combine
#endif

/// A meeting as a client that cannot read the Mac's folders sees it.
struct MeetingInfo: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    /// The first line of the summary that is not a heading, or of the transcript.
    var preview: String
    var hasSummary: Bool
    var hasTranscript: Bool
    /// The audio chunks are still there, so the transcript can be made again.
    var hasAudio: Bool
    /// The meeting is being recorded or summarized now.
    var active: Bool
}

enum MeetingText: String, Codable {
    case summary, transcript
}

struct MeetingTextRequest: Codable, Equatable {
    var id: String
    var kind: MeetingText
}

enum MeetingRegeneration: String, Codable {
    /// Transcribe every saved chunk again, then summarize.
    case full
    /// Summarize the transcript that is already there, for example after a speaker was named.
    case summaryOnly
}

struct RegenerateMeetingRequest: Codable, Equatable {
    var id: String
    var mode: MeetingRegeneration = .full
}

struct NameSpeakerRequest: Codable, Equatable {
    var speaker: Int
    var name: String
}

struct DismissSpeakerRequest: Codable, Equatable {
    var speaker: Int
    /// Two people share this voice, so it cannot be named.
    var mixed = false
}

struct MeetingStatus: Codable, Equatable {
    /// `idle`, `choosing`, `recording`, `finishing`, `summarizing` or `done`.
    var phase: String
    var folder: String?
    var appName: String
    var startedAt: Date?
    /// Chunks of the open recording that are transcribed, waiting and failed.
    var chunksDone: Int
    var chunksWaiting: Int
    var chunksFailed: Int
    /// Voices of the last meeting that still need a name.
    var speakersToName: Int
}

/// Meetings and their transcripts: list, summary and transcript text, regenerate, ask, delete, stop recording, name a speaker.
///
/// This is an `ObservableObject` so the transcripts page and the recording panel redraw as meetings change.
@MainActor
final class MeetingsAPI {
    /// Fires before the recording, the library or a regeneration change.
    let changes = ChangeSignal()
    private let recorder: MeetingRecorder
    private let library: MeetingLibrary
    private var forwarding: [ChangeToken] = []

    /// Opens the chat with these files attached. The app owner sets it.
    var askHandler: (([URL]) -> Void)?

    init(recorder: MeetingRecorder, library: MeetingLibrary) {
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
    var meetings: [MeetingRecord] { library.meetings }

    func reload() { library.reload() }

    func list() -> [MeetingInfo] {
        let active = activeFolder
        return library.meetings.map { MeetingInfo(id: $0.id, date: $0.date, preview: $0.preview, hasSummary: $0.hasSummary,
                                                  hasTranscript: $0.hasTranscript, hasAudio: $0.hasAudio, active: $0.folder == active) }
    }

    func get(_ id: String) throws -> MeetingInfo {
        guard let info = list().first(where: { $0.id == id }) else { throw APIError.notFound("no meeting with id \"\(id)\"") }
        return info
    }

    /// The summary or transcript text. Nil when the meeting has no such file yet. The read runs off the main thread.
    func text(_ request: MeetingTextRequest) async throws -> String? {
        let record = try record(request.id)
        let url = request.kind == .summary ? record.summaryURL : record.transcriptURL
        return await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
    }

    /// Moves the meeting's folder to the Trash. The meeting being recorded or rebuilt cannot be deleted.
    func delete(_ id: String) throws {
        let record = try record(id)
        guard record.folder != activeFolder, regenerationID != id else { throw APIError.conflict("this meeting is still being recorded or rebuilt") }
        do { try library.delete(id) } catch { throw APIError.failed("Could not move it to the Trash: \(error.localizedDescription)") }
    }

    /// Opens the chat with the meeting's transcript and summary attached.
    func ask(_ id: String) throws {
        let files = try record(id).chatFiles
        guard !files.isEmpty else { throw APIError.invalid("this meeting has no transcript or summary yet") }
        guard let askHandler else { throw APIError.unavailable("the chat is not available") }
        askHandler(files)
    }

    // MARK: Regeneration

    var regenerationID: String? { library.regenerator.activeID }
    var regenerationProgress: RegenerationProgress? { library.regenerator.progress }
    var regenerationErrors: [String: String] { library.regenerator.errors }
    /// Counts finished runs, so a view knows when the files on disk changed.
    var regenerationsCompleted: Int { library.regenerator.completed }

    /// Why a meeting cannot be rebuilt now, or nil when it can.
    func regenerationBlocked(_ id: String, mode: MeetingRegeneration = .full) -> String? {
        guard let record = try? record(id) else { return "No such meeting." }
        return library.regenerator.unavailableReason(for: record, activeFolder: activeFolder, requiresAudio: mode == .full)
    }

    /// Makes a new transcript and summary. The old files stay as `.prev.md`.
    func regenerate(_ request: RegenerateMeetingRequest) async throws {
        let record = try record(request.id)
        let ok = await library.regenerator.regenerate(record, mode: request.mode == .full ? .full : .summaryOnly, activeFolder: activeFolder)
        if !ok { throw APIError.failed(library.regenerator.errors[record.id] ?? "The meeting could not be rebuilt.") }
    }

    // MARK: Recording

    var status: MeetingStatus {
        let counts = recorder.counts
        return MeetingStatus(phase: recorder.phase.rawValue, folder: recorder.folder?.path, appName: recorder.appName,
                             startedAt: recorder.startedAt, chunksDone: counts.done, chunksWaiting: counts.waiting,
                             chunksFailed: counts.failed, speakersToName: recorder.speakersToName.count)
    }

    /// The folder of the meeting being recorded or summarized, if any.
    var activeFolder: URL? {
        [.recording, .finishing, .summarizing].contains(recorder.phase) ? recorder.folder : nil
    }

    /// Ends the recording. The transcript and summary follow.
    func stopRecording() throws {
        guard recorder.isRecording else { throw APIError.conflict("no meeting is being recorded") }
        do { try recorder.stop() } catch { throw APIError.unavailable(error.localizedDescription) }
    }

    // MARK: Speakers

    func nameSpeaker(_ request: NameSpeakerRequest) throws {
        guard recorder.speakersToName.contains(where: { $0.id == request.speaker }) || recorder.speakerTable.speaker(request.speaker) != nil else {
            throw APIError.notFound("no speaker \(request.speaker) in the last meeting")
        }
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.invalid("the name is empty") }
        recorder.nameSpeaker(request.speaker, as: request.name)
    }

    func dismissSpeaker(_ request: DismissSpeakerRequest) throws {
        guard recorder.speakerTable.speaker(request.speaker) != nil else { throw APIError.notFound("no speaker \(request.speaker) in the last meeting") }
        recorder.dismissSpeaker(request.speaker, mixed: request.mixed)
    }

    // MARK: Stored voices

    /// The voices ironpet recognises in later meetings, each with how much speech it holds.
    func voiceprints() -> [StoredVoice] { recorder.voiceStore.voices() }

    /// Whether the encrypted voice file exists, even when it holds no voice ironpet can read.
    var hasVoiceFile: Bool { recorder.voiceStore.hasFile }

    func forgetVoice(_ id: String) throws {
        guard recorder.voiceStore.voices().contains(where: { $0.id == id }) else { throw APIError.notFound("no stored voice with id \"\(id)\"") }
        recorder.voiceStore.forget(id: id)
    }

    func forgetAllVoices() { recorder.voiceStore.forgetAll() }

    // MARK: The recording panel

    var phase: MeetingPhase { recorder.phase }
    var apps: [AudioApp] { recorder.apps }
    var choice: AudioChoice { get { recorder.choice } set { recorder.choice = newValue } }
    var notice: String? { recorder.notice }
    var appName: String { recorder.appName }
    var startedAt: Date? { recorder.startedAt }
    /// The name of the folder the open meeting is saved in.
    var folderLabel: String { recorder.folder?.lastPathComponent ?? "" }
    var myLevels: LevelBuffer { recorder.myLevels }
    var theirLevels: LevelBuffer { recorder.theirLevels }
    var counts: (done: Int, waiting: Int, failed: Int) { recorder.counts }
    var recentLines: [MeetingLine] { recorder.recentLines }
    var summaryState: MeetingSummaryState { recorder.summary }
    /// Starts a recording. Where nothing can record, it does nothing.
    func start() { try? recorder.start() }
    func dismiss() { recorder.dismiss() }
    func confirmDiscard() { recorder.confirmDiscard() }
    func retryFailed() { recorder.retryFailed() }
    func openTranscript() { recorder.openTranscript() }
    func openSummary() { recorder.openSummary() }
    func openInChat() { recorder.openInChat() }
    /// Opens Settings on the Meetings page, where voices are named.
    func labelSpeakers() { recorder.onLabelSpeakers?() }

    // Naming the voices of the last meeting.
    var hasSpeakersToName: Bool { recorder.hasSpeakersToName }
    var speakersToName: [MeetingSpeaker] { recorder.speakersToName }
    var storedNames: [String] { recorder.storedNames }
    func knownNames(stored: [String]) -> [String] { recorder.knownNames(stored: stored) }
    func sampleLine(for id: Int) -> String? { recorder.sampleLine(for: id) }
    var canRegenerateSummary: Bool { recorder.canRegenerateSummary }
    var regeneratingSummary: Bool { recorder.regeneratingSummary }
    func regenerateSummary() { recorder.regenerateSummary() }

    private func record(_ id: String) throws -> MeetingRecord {
        guard let record = library.meetings.first(where: { $0.id == id }) else { throw APIError.notFound("no meeting with id \"\(id)\"") }
        return record
    }
}

#if canImport(Combine)

extension MeetingsAPI: ObservableObject {
    nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
