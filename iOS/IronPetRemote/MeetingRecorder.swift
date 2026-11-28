import ActivityKit
import Foundation
import IronPetKit
import Observation

/// Starts and ends the Live Activity of a recording. Tests pass a fake, because Live Activities do not run in the simulator tests.
@MainActor
protocol RecordingActivityControlling: AnyObject {
    func start(startedAt: Date)
    func end()
}

@MainActor
final class RecordingActivity: RecordingActivityControlling {
    private var activity: Activity<MeetingRecordingAttributes>?

    func start(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: MeetingRecordingAttributes.ContentState(recording: true), staleDate: nil)
        activity = try? Activity.request(attributes: MeetingRecordingAttributes(startedAt: startedAt), content: content)
    }

    func end() {
        let ending = activity
        activity = nil
        Task { await ending?.end(ActivityContent(state: .init(recording: false), staleDate: nil), dismissalPolicy: .immediate) }
    }
}

/// Records the room through the microphone and writes the audio as 30 second WAV chunks into `MeetingRecordingQueue`, which the upload
/// model sends to the Mac while recording goes on. The chunk is on disk before anything is sent, so a Mac that cannot be reached loses
/// nothing. Recording keeps going with the screen locked, because the app has the `audio` background mode and the engine runs a
/// `playAndRecord` session, the same one voice mode uses.
@MainActor @Observable
final class MeetingRecorder {
    enum State: Equatable { case idle, starting, recording }

    private(set) var state: State = .idle
    private(set) var startedAt: Date?
    /// The recording that is running, so the list of waiting recordings does not show it twice.
    private(set) var currentID: String?
    /// Why the last recording could not start or ended early, in words for the screen.
    var message: String?

    @ObservationIgnored private let queue: MeetingRecordingQueue
    @ObservationIgnored private let makeSource: () -> MicSource
    @ObservationIgnored private let activity: RecordingActivityControlling
    @ObservationIgnored private var source: MicSource?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Called after a chunk reached the disk and after the recording ended, so the upload model sends what waits.
    @ObservationIgnored var onChunk: @MainActor () -> Void = {}

    init(queue: MeetingRecordingQueue, makeSource: @escaping () -> MicSource = { EngineMicSource() }, activity: RecordingActivityControlling? = nil) {
        self.queue = queue
        self.makeSource = makeSource
        self.activity = activity ?? RecordingActivity()
        // A recording the app died in has its chunks on disk. It goes to the Mac as a meeting.
        queue.closeInterrupted()
        observer = NotificationCenter.default.addObserver(forName: .stopMeetingRecording, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var isRecording: Bool { state != .idle }

    func start() {
        guard state == .idle else { return }
        message = nil
        state = .starting
        let source = makeSource()
        self.source = source
        // The microphone stopped on its own (a route change, a call). What was captured is kept and sent.
        source.onFailure = { [weak self] reason in Task { @MainActor in self?.message = reason } }
        source.onInterrupted = { [weak self] reason in Task { @MainActor in self?.message = reason } }
        task = Task { [weak self] in
            do {
                let stream = try await source.start()
                guard let self else { return }
                try await self.run(stream)
            } catch {
                self?.finish(failure: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Ends the recording. The audio so far becomes a meeting.
    func stop() {
        guard state != .idle else { return }
        source?.stop()
    }

    private func run(_ stream: AsyncStream<Data>) async throws {
        let recording = try queue.begin()
        let started = recording.startedAt
        currentID = recording.id
        startedAt = started
        state = .recording
        activity.start(startedAt: started)
        var buffer = Data()
        for await pcm in stream {
            buffer.append(pcm)
            while buffer.count >= MeetingRecordingFormat.chunkBytes {
                try write(buffer.prefix(MeetingRecordingFormat.chunkBytes), to: recording.id)
                buffer.removeFirst(MeetingRecordingFormat.chunkBytes)
            }
        }
        // The stream ended: Stop, or the microphone went away. The rest of the last chunk is kept.
        if !buffer.isEmpty { try write(buffer, to: recording.id) }
        queue.stop(recording.id)
        finish(failure: nil)
    }

    private func write(_ pcm: Data, to id: String) throws {
        try queue.append(id, wav: MeetingRecordingFormat.wav(pcm: Data(pcm)))
        onChunk()
    }

    private func finish(failure: String?) {
        if let failure { message = failure }
        for recording in queue.pending where !recording.stopped { queue.stop(recording.id) }
        activity.end()
        source?.stop()
        source = nil
        task = nil
        startedAt = nil
        currentID = nil
        state = .idle
        onChunk()
    }
}
