import Foundation

enum MeetingPhase: String { case idle, choosing, recording, finishing, summarizing, done }

enum MeetingSummaryState: Equatable {
    case none, running, ready(URL), failed(String)
}

/// Records a meeting and turns it into a transcript and summary. The Mac adapter is `MeetingController`, which listens to
/// system audio and the microphone. `MeetingsAPI` reads and drives a meeting only through this protocol.
@MainActor
protocol MeetingRecorder: AnyObject {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    nonisolated var isSupported: Bool { get }
    /// Fires before the recording state changes.
    var changes: ChangeSignal { get }
    /// Where `meetings.changed` is published for API clients.
    var events: APIEventBus? { get set }

    // State
    var phase: MeetingPhase { get }
    var isRecording: Bool { get }
    var apps: [AudioApp] { get }
    var choice: AudioChoice { get set }
    var notice: String? { get }
    var appName: String { get }
    var startedAt: Date? { get }
    var folder: URL? { get }
    var myLevels: LevelBuffer { get }
    var theirLevels: LevelBuffer { get }
    var counts: (done: Int, waiting: Int, failed: Int) { get }
    var recentLines: [MeetingLine] { get }
    var summary: MeetingSummaryState { get }
    var canRegenerateSummary: Bool { get }
    var regeneratingSummary: Bool { get }

    // Speakers and stored voices
    var speakerTable: MeetingSpeakerTable { get }
    var speakersToName: [MeetingSpeaker] { get }
    var hasSpeakersToName: Bool { get }
    var storedNames: [String] { get }
    var voiceStore: VoiceStore { get }
    /// Opens Settings on the Meetings page, where voices are named.
    var onLabelSpeakers: (() -> Void)? { get }
    func knownNames(stored: [String]) -> [String]
    func sampleLine(for id: Int) -> String?
    func nameSpeaker(_ id: Int, as name: String)
    func dismissSpeaker(_ id: Int, mixed: Bool)

    // Actions
    /// Starts recording with the current `choice`. Throws `CapabilityError.unsupported` where nothing can record.
    func start() throws
    /// Ends the recording. The transcript and summary follow. Throws `CapabilityError.unsupported` where nothing can record.
    func stop() throws
    func dismiss()
    func confirmDiscard()
    func retryFailed()
    func openTranscript()
    func openSummary()
    func openInChat()
    func regenerateSummary()
}

extension MeetingRecorder {
    nonisolated var isSupported: Bool { true }
}

/// A recorder that cannot record. `MeetingsAPI` over it reports an idle meeting and refuses to start one.
@MainActor
final class UnsupportedMeetingRecorder: MeetingRecorder {
    var platform = PlatformName.current
    nonisolated var isSupported: Bool { false }
    let changes = ChangeSignal()
    weak var events: APIEventBus?

    var phase: MeetingPhase { .idle }
    var isRecording: Bool { false }
    var apps: [AudioApp] { [] }
    var choice: AudioChoice = .allSystemAudio
    var notice: String? { nil }
    var appName: String { "" }
    var startedAt: Date? { nil }
    var folder: URL? { nil }
    let myLevels = LevelBuffer()
    let theirLevels = LevelBuffer()
    var counts: (done: Int, waiting: Int, failed: Int) { (0, 0, 0) }
    var recentLines: [MeetingLine] { [] }
    var summary: MeetingSummaryState { .none }
    var canRegenerateSummary: Bool { false }
    var regeneratingSummary: Bool { false }
    var speakerTable: MeetingSpeakerTable { MeetingSpeakerTable() }
    var speakersToName: [MeetingSpeaker] { [] }
    var hasSpeakersToName: Bool { false }
    var storedNames: [String] { [] }
    let voiceStore: VoiceStore = .unwired
    var onLabelSpeakers: (() -> Void)? { nil }

    init() {}

    private var error: CapabilityError { .unsupported(capability: "MeetingRecorder", platform: platform) }

    func knownNames(stored: [String]) -> [String] { stored }
    func sampleLine(for id: Int) -> String? { nil }
    func nameSpeaker(_ id: Int, as name: String) {}
    func dismissSpeaker(_ id: Int, mixed: Bool) {}
    func start() throws { throw error }
    func stop() throws { throw error }
    func dismiss() {}
    func confirmDiscard() {}
    func retryFailed() {}
    func openTranscript() {}
    func openSummary() {}
    func openInChat() {}
    func regenerateSummary() {}
}
