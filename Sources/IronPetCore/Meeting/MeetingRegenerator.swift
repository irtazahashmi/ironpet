import Foundation
#if canImport(Combine)
import Combine
#endif

package enum RegenerationMode: Equatable {
    /// Transcribe every saved chunk again, then summarise the new transcript.
    case full
    /// Summarise the transcript.md that is already there, for example after a speaker was named.
    case summaryOnly
}

package struct RegenerationProgress: Equatable {
    package init(stage: Stage) {
        self.stage = stage
    }

    package enum Stage: Equatable {
        case reading
        case transcribing(chunk: Int, of: Int)
        case summarising
    }

    package var stage: Stage

    package var label: String {
        switch stage {
        case .reading: return "Reading audio"
        case .transcribing(let chunk, let total): return "Transcribing chunk \(chunk) of \(total)"
        case .summarising: return "Summarising"
        }
    }
}

package struct RegenerationError: LocalizedError {
    package init(message: String) {
        self.message = message
    }

    package let message: String
    package var errorDescription: String? { message }
}

/// What a finished regeneration changed, for the caller that offers the new action items as tasks.
package struct MeetingReplacement {
    package init(folder: URL, mode: RegenerationMode, previousSummary: String? = nil, summary: String, agent: String? = nil) {
        self.folder = folder
        self.mode = mode
        self.previousSummary = previousSummary
        self.summary = summary
        self.agent = agent
    }

    package var folder: URL
    package var mode: RegenerationMode
    package var previousSummary: String?
    package var summary: String
    /// The summary agent that wrote it, read before the run, since the setting may change while it runs.
    package var agent: String? = nil
}

/// Reads a meeting folder's audio chunks and the facts the transcript header needs.
package enum MeetingFolderScan {
    package struct Result {
        package init(chunks: [ChunkInfo], startedAt: Date, appName: String) {
            self.chunks = chunks
            self.startedAt = startedAt
            self.appName = appName
        }

        package var chunks: [ChunkInfo]
        package var startedAt: Date
        package var appName: String
    }

    /// `mic-001.wav` or `them-012.wav` gives the track and chunk number; any other name gives nil.
    package static func chunkName(_ name: String) -> (track: MeetingTrack, index: Int)? {
        let parts = name.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[1].hasSuffix(".wav"), let index = Int(parts[1].dropLast(4)),
              let track = MeetingTrack.allCases.first(where: { $0.filePrefix == parts[0] }) else { return nil }
        return (track, index)
    }

    /// Chunks of both tracks in meeting order. Offsets are the summed lengths of the earlier chunks of the same
    /// track, which is how `TrackRecorder` counted them. Reads every file, so call it off the main thread.
    package static func scan(_ folder: URL) throws -> Result {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var chunks: [ChunkInfo] = []
        var firstWritten: [Date] = []
        for track in MeetingTrack.allCases {
            var offset: TimeInterval = 0
            let files = names.compactMap { name in chunkName(name).flatMap { $0.track == track ? ($0.index, name) : nil } }.sorted { $0.0 < $1.0 }
            for (number, (index, name)) in files.enumerated() {
                let url = folder.appendingPathComponent(name)
                let samples = WAV.samples(of: try Data(contentsOf: url))
                let duration = Double(samples.count) / Double(WAV.sampleRate)
                chunks.append(ChunkInfo(track: track, index: index, url: url, offset: offset, duration: duration,
                                        silent: Chunker.isSilent(samples) || samples.count < WAV.sampleRate / 4))
                // A chunk's file is written when it closes, so its time minus its length is when the recording began.
                if number == 0, let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    firstWritten.append(written.addingTimeInterval(-duration))
                }
                offset += duration
            }
        }
        chunks.sort { ($0.offset, $0.track) < ($1.offset, $1.track) }
        let minute = MeetingLibrary.date(folderName: folder.lastPathComponent) ?? Date()
        // The folder name only knows the minute. The files know the second, which keeps the clock times of a new
        // transcript equal to the old one. A time outside that minute means the files were copied, so it is ignored.
        let exact = firstWritten.min().flatMap { $0 >= minute && $0 < minute.addingTimeInterval(60) ? $0 : nil }
        let old = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        return Result(chunks: chunks, startedAt: exact ?? minute, appName: appName(fromTranscript: old))
    }

    /// The app in `# Meeting 2026-11-14 14:00 (Zoom)`.
    package static func appName(fromTranscript text: String?) -> String {
        guard let first = text?.components(separatedBy: "\n").first, first.hasPrefix("# Meeting "), first.hasSuffix(")"),
              let open = first.firstIndex(of: "(") else { return "unknown app" }
        let name = first[first.index(after: open)..<first.index(before: first.endIndex)]
        return name.isEmpty ? "unknown app" : String(name)
    }
}

/// Rebuilds a past meeting's transcript and summary with the settings in force now: the transcription model, the
/// voices in the store and the summary agent. Nothing in the folder changes until everything succeeded, and the files
/// it replaces stay as `transcript.prev.md` and `summary.prev.md`.
@MainActor
package final class MeetingRegenerator {
    package init() {}

    /// Fires before any of the properties below change.
    package let changes = ChangeSignal()
    /// The meeting being rebuilt. One at a time.
    package private(set) var activeID: String? { willSet { changes.send() } }
    package private(set) var progress: RegenerationProgress? { willSet { changes.send() } }
    /// The last failure for each meeting, until it is tried again.
    package private(set) var errors: [String: String] = [:] { willSet { changes.send() } }
    /// Counts finished runs, so a view knows when the files on disk changed.
    package private(set) var completed = 0 { willSet { changes.send() } }

    /// The voice server's key. `AppDelegate` shares the meeting controller's.
    package var keyCache = MeetingKeyCache(voiceKey: .unsupported)
    package lazy var makeTranscriber: () -> Transcriber = { [weak self] in
        let voice = ConfigStore.shared.config.voice
        return Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: self?.keyCache.key(), usageFeature: .meetingTranscription)
    }
    /// Splits speakers inside a chunk. `AppDelegate` sets the Mac one; without it the transcript stays by track.
    package var diarizer: SpeakerDiarizing = UnsupportedDiarizer()
    package var voiceStore: VoiceStore = .unwired
    /// Starts the summary agent. `AppDelegate` sets the Mac one.
    package var spawner: ProcessSpawner = UnsupportedProcessSpawner()
    package var recogniseSpeakers: () -> Bool = { ConfigStore.shared.config.meetings.recogniseSpeakers }
    /// True once the diarization models are on disk. `AppDelegate` sets the Mac check.
    package var speakerModelsReady: () -> Bool = { false }
    package var meetingConfig: () -> Config.Meetings = { ConfigStore.shared.config.meetings }
    /// Runs the summary agent on a transcript and returns its answer. Tests replace it.
    package lazy var summarize: @MainActor (_ transcript: String, _ config: Config.Meetings, _ folder: URL, _ suggest: Bool) async throws -> String = { [weak self] transcript, config, folder, suggest in
        try await MeetingSummaryRun.run(transcript: transcript, config: config, folder: folder, spawner: self?.spawner ?? UnsupportedProcessSpawner(), suggest: suggest)
    }
    /// Called after the files were replaced.
    package var onReplaced: ((MeetingReplacement) -> Void)?
    /// The voices of meetings rebuilt in this session, by meeting id and transcript label (`Speaker 2`). They stay in memory
    /// only, so a suggested name can be stored as a voice. Nothing about a voice is written to the meeting folder.
    package var speakerVoices: [String: [String: MeetingSpeaker]] = [:]

    /// Remembers the voices of a meeting that was just recorded, keyed by the label its transcript shows.
    package func rememberVoices(meetingID: String, _ speakers: [MeetingSpeaker]) {
        speakerVoices[meetingID] = Dictionary(speakers.filter { $0.name == nil }.map { ($0.displayName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Why the Regenerate button is disabled for this meeting, or nil when it can run. `activeFolder` is the meeting
    /// being recorded or summarised right now.
    package func unavailableReason(for meeting: MeetingRecord, activeFolder: URL?, requiresAudio: Bool = true) -> String? {
        if let activeFolder, activeFolder.standardizedFileURL.path == meeting.folder.standardizedFileURL.path {
            return "This meeting is still being recorded or summarised."
        }
        if let activeID { return activeID == meeting.id ? "This meeting is being regenerated." : "Another meeting is being regenerated." }
        if requiresAudio, !meeting.hasAudio { return "This meeting has no saved audio to transcribe again." }
        return nil
    }

    /// Rebuilds the meeting. Returns false, with the reason in `errors`, when it could not start or failed.
    /// `appName` replaces the one in the old transcript header, for a meeting that has no transcript yet.
    @discardableResult
    package func regenerate(_ meeting: MeetingRecord, mode: RegenerationMode, activeFolder: URL? = nil, appName: String? = nil) async -> Bool {
        if let reason = unavailableReason(for: meeting, activeFolder: activeFolder, requiresAudio: mode == .full) {
            errors[meeting.id] = reason
            return false
        }
        activeID = meeting.id
        errors[meeting.id] = nil
        progress = RegenerationProgress(stage: .reading)
        defer {
            activeID = nil
            progress = nil
            completed += 1
        }
        do {
            let replacement = try await rebuild(meeting, mode: mode, appName: appName)
            onReplaced?(replacement)
            return true
        } catch {
            errors[meeting.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// For the preview renderer: shows a run in progress without doing any work.
    package func loadPreview(active meeting: String, _ stage: RegenerationProgress.Stage) {
        activeID = meeting
        progress = RegenerationProgress(stage: stage)
    }

    package func clearPreview() {
        activeID = nil
        progress = nil
    }

    private func rebuild(_ meeting: MeetingRecord, mode: RegenerationMode, appName: String?) async throws -> MeetingReplacement {
        let folder = meeting.folder
        let previous = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        var transcript: String?
        var voices: MeetingSpeakerTable?
        let text: String
        switch mode {
        case .full:
            keyCache.forget()
            let found = try await Self.scan(folder)
            let (lines, table) = try await transcribe(found.chunks)
            voices = table
            guard !lines.isEmpty else { throw RegenerationError(message: "The new transcript has no speech in it, so nothing was replaced.") }
            text = MeetingTranscript.render(startedAt: found.startedAt, appName: appName ?? found.appName, lines: lines)
            transcript = text
        case .summaryOnly:
            guard let existing = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8),
                  !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RegenerationError(message: "This meeting has no transcript to summarise.")
            }
            text = existing
        }
        progress = RegenerationProgress(stage: .summarising)
        let config = meetingConfig()
        // Room and imported meetings also get a suggested title and speaker names. A call meeting is asked for neither.
        let suggest = meeting.isRoom
        let answer = try await summarize(text, config, folder, suggest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw RegenerationError(message: "The agent returned no text, so nothing was replaced.") }
        let parsed = suggest ? MeetingSuggestions.parse(answer) : (summary: answer, suggestions: MeetingSuggestions())
        var summary = (parsed.summary.isEmpty ? answer : parsed.summary) + "\n"
        if let previous { summary = ActionItems.carryChecked(from: previous, into: summary) }
        try Self.replace(in: folder, transcript: transcript, summary: summary)
        parsed.suggestions.limited(toTranscript: text).save(to: folder)
        if let voices {
            speakerVoices[meeting.id] = Dictionary(voices.speakers.filter { $0.name == nil }.map { ($0.displayName, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return MeetingReplacement(folder: folder, mode: mode, previousSummary: previous, summary: summary, agent: config.summaryAgent)
    }

    /// Transcribes the chunks in meeting order, and when speaker recognition is on, names the voices on the Them track.
    private func transcribe(_ chunks: [ChunkInfo]) async throws -> ([MeetingLine], MeetingSpeakerTable) {
        let work = chunks.filter { !$0.silent }
        let diarize = recogniseSpeakers() && speakerModelsReady()
        var table = MeetingSpeakerTable()
        var lines: [MeetingLine] = []
        for (number, chunk) in work.enumerated() {
            progress = RegenerationProgress(stage: .transcribing(chunk: number + 1, of: work.count))
            let splitter: SpeakerDiarizing? = chunk.track.hasSeveralVoices && diarize ? diarizer : nil
            let segments: [TimedSegment]
            let speakers: ChunkDiarization?
            do {
                (segments, speakers) = try await Self.transcribe(chunk, make: makeTranscriber, diarizer: splitter)
            } catch {
                throw RegenerationError(message: "Could not transcribe \(chunk.url.lastPathComponent): "
                    + "\(error.localizedDescription) The transcript and summary are unchanged.")
            }
            var turns: [SpeakerTurn] = []
            if let speakers {
                let ids = table.link(speakers, chunkURL: chunk.url, store: voiceStore.candidates)
                for speaker in speakers.speakers {
                    guard let id = ids[speaker.localId] else { continue }
                    turns += speaker.turns.map { SpeakerTurn(speakerId: id, start: $0.lowerBound, end: $0.upperBound) }
                }
            }
            lines += MeetingTranscript.lines(from: segments, track: chunk.track, offset: chunk.offset, turns: turns)
        }
        if !table.speakers.isEmpty {
            // The same last pass a live meeting makes: a voice recognised late is named in the early chunks too.
            let remap = table.relink(store: voiceStore.candidates)
            for index in lines.indices {
                if let id = lines[index].speakerId, let to = remap[id] { lines[index].speakerId = to }
                if let id = lines[index].speakerId, let speaker = table.speaker(id) { lines[index].speaker = speaker.displayName }
            }
        }
        return (lines, table)
    }

    private nonisolated static func scan(_ folder: URL) async throws -> MeetingFolderScan.Result {
        try MeetingFolderScan.scan(folder)
    }

    /// A diarization failure is not a transcription failure: the lines keep the track name, as in a live meeting.
    private nonisolated static func transcribe(_ chunk: ChunkInfo, make: () -> Transcriber,
                                               diarizer: SpeakerDiarizing?) async throws -> ([TimedSegment], ChunkDiarization?) {
        let transcriber = make()
        let segments = try await transcriber.transcribeSegments(wav: try Data(contentsOf: chunk.url))
        let speakers = diarizer == nil ? nil : try? await diarizer?.diarize(wav: chunk.url)
        return (segments, speakers)
    }

    /// Writes the new files next to the old ones, then swaps. When a swap fails, the ones already made are undone.
    package nonisolated static func replace(in folder: URL, transcript: String?, summary: String,
                                    move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let fm = FileManager.default
        var parts: [(name: String, text: String)] = [("summary", summary)]
        if let transcript { parts.insert(("transcript", transcript), at: 0) }
        func url(_ name: String, _ suffix: String) -> URL { folder.appendingPathComponent("\(name)\(suffix).md") }
        do {
            for part in parts { try part.text.write(to: url(part.name, ".new"), atomically: true, encoding: .utf8) }
        } catch {
            for part in parts { try? fm.removeItem(at: url(part.name, ".new")) }
            throw error
        }
        var swapped: [(name: String, hadOld: Bool)] = []
        do {
            for part in parts {
                let hadOld = fm.fileExists(atPath: url(part.name, "").path)
                if hadOld {
                    try? fm.removeItem(at: url(part.name, ".prev"))
                    try move(url(part.name, ""), url(part.name, ".prev"))
                }
                swapped.append((part.name, hadOld))
                try move(url(part.name, ".new"), url(part.name, ""))
            }
        } catch {
            for done in swapped.reversed() {
                try? fm.removeItem(at: url(done.name, ""))
                if done.hadOld { try? move(url(done.name, ".prev"), url(done.name, "")) }
            }
            for part in parts { try? fm.removeItem(at: url(part.name, ".new")) }
            throw RegenerationError(message: "Could not replace the files: \(error.localizedDescription) The old ones were put back.")
        }
    }
}

/// Runs the summary agent once, the way the live recorder does: read-only, every permission refused.
@MainActor
package enum MeetingSummaryRun {
    package static func run(transcript: String, config: Config.Meetings, folder: URL, spawner: ProcessSpawner, suggest: Bool = false) async throws -> String {
        guard let agent = AgentCatalog.agent(id: config.summaryAgent) else {
            throw RegenerationError(message: "The summary agent \"\(config.summaryAgent)\" is not available. Pick another in Settings → Meetings.")
        }
        let runner = MeetingSummary.makeRunner(agent, spawner: spawner)
        let turn = ACPTurn(prompt: MeetingSummary.prompt(transcript: transcript, suggest: suggest), preamble: nil, workspace: folder,
                           resume: nil, model: config.summaryModel, images: [], files: [])
        var tasks: [Task<Void, Never>] = []
        defer {
            tasks.forEach { $0.cancel() }
            runner.cancel()
            runner.shutdown()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = Gate(continuation)
            var answer = ""
            tasks.append(Task {
                await runner.runTurn(turn) { event in
                    switch event {
                    case .assistant(let chunk): answer += chunk
                    case .finished(let error):
                        gate.finish(error.map { .failure(RegenerationError(message: $0)) } ?? .success(answer))
                    case .needsSignIn:
                        gate.finish(.failure(RegenerationError(message: "\(agent.name) needs you to sign in. Open it in the chat once, then try again.")))
                    case .needsRuntime:
                        gate.finish(.failure(RegenerationError(message: "\(agent.name) needs Node 22 or Bun. Open it in the chat once to set that up.")))
                    default: break
                    }
                }
            })
            tasks.append(Task {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                gate.finish(.failure(RegenerationError(message: "The agent did not answer within 10 minutes.")))
            })
        }
    }

    /// Resumes the continuation once, whichever of the answer, an error or the timeout comes first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?

        init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}

#if canImport(Combine)

extension MeetingRegenerator: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
