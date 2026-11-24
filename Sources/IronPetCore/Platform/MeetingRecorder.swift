import Foundation
import IronPetKit

package enum MeetingPhase: String { case idle, choosing, recording, finishing, summarizing, done }

package enum MeetingSummaryState: Equatable {
    case none, running, ready(URL), failed(String)
}

/// Records a meeting and turns it into a transcript and summary. The Mac adapter is `MeetingController`, which listens to
/// system audio and the microphone. `MeetingsAPI` reads and drives a meeting only through this protocol.
@MainActor
package protocol MeetingRecorder: AnyObject {
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
    package nonisolated var isSupported: Bool { true }
}

/// A recorder that cannot record. `MeetingsAPI` over it reports an idle meeting and refuses to start one.
@MainActor
package final class UnsupportedMeetingRecorder: MeetingRecorder {
    package var platform = PlatformName.current
    package nonisolated var isSupported: Bool { false }
    package let changes = ChangeSignal()
    package weak var events: APIEventBus?

    package var phase: MeetingPhase { .idle }
    package var isRecording: Bool { false }
    package var apps: [AudioApp] { [] }
    package var choice: AudioChoice = .allSystemAudio
    package var notice: String? { nil }
    package var appName: String { "" }
    package var startedAt: Date? { nil }
    package var folder: URL? { nil }
    package let myLevels = LevelBuffer()
    package let theirLevels = LevelBuffer()
    package var counts: (done: Int, waiting: Int, failed: Int) { (0, 0, 0) }
    package var recentLines: [MeetingLine] { [] }
    package var summary: MeetingSummaryState { .none }
    package var canRegenerateSummary: Bool { false }
    package var regeneratingSummary: Bool { false }
    package var speakerTable: MeetingSpeakerTable { MeetingSpeakerTable() }
    package var speakersToName: [MeetingSpeaker] { [] }
    package var hasSpeakersToName: Bool { false }
    package var storedNames: [String] { [] }
    package let voiceStore: VoiceStore = .unwired
    package var onLabelSpeakers: (() -> Void)? { nil }

    package init() {}

    private var error: CapabilityError { .unsupported(capability: "MeetingRecorder", platform: platform) }

    package func knownNames(stored: [String]) -> [String] { stored }
    package func sampleLine(for id: Int) -> String? { nil }
    package func nameSpeaker(_ id: Int, as name: String) {}
    package func dismissSpeaker(_ id: Int, mixed: Bool) {}
    package func start() throws { throw error }
    package func stop() throws { throw error }
    package func dismiss() {}
    package func confirmDiscard() {}
    package func retryFailed() {}
    package func openTranscript() {}
    package func openSummary() {}
    package func openInChat() {}
    package func regenerateSummary() {}
}
