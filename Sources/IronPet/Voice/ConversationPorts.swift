import Foundation

/// What a voice conversation's microphone reports.
enum ConversationMicEvent: Equatable {
    case speechStarted
    /// One utterance as a 16 kHz mono WAV.
    case utterance(Data)
    /// Something too short to be speech ended.
    case discarded
    case failed(String)
}

/// What `VoiceConversation` needs from the microphone. `ConversationMic` is the Mac one; tests send events by hand.
@MainActor
protocol ConversationListening: AnyObject {
    var onEvent: ((ConversationMicEvent) -> Void)? { get set }
    var levels: LevelBuffer { get }
    /// Plays the pet's voice. Through the microphone's own engine, so echo cancellation knows what to take out.
    var player: ClipPlaying { get }
    /// Throws `CapabilityError.unsupported` where nothing can listen.
    func start() throws
    func stop()
    /// True while the pet speaks: speech must then be louder and longer to count, so the pet does not interrupt itself.
    func setPlayback(_ on: Bool)
}

/// Speaks a line and returns when it has been heard. `SpeechPlayer` is the Mac one.
@MainActor
protocol ConversationSpeaker: AnyObject {
    /// Throws `CancellationError` when `stop()` cut it short, or what the speech server answered. Throws
    /// `CapabilityError.unsupported` where nothing can play.
    func say(_ text: String) async throws
    func stop()
}

/// Hears nothing.
@MainActor
final class UnsupportedConversationMic: ConversationListening {
    var platform = PlatformName.current
    var onEvent: ((ConversationMicEvent) -> Void)?
    let levels = LevelBuffer()
    var player: ClipPlaying { UnsupportedClipPlayer(platform: platform) }

    init() {}

    func start() throws { throw CapabilityError.unsupported(capability: "ConversationListening", platform: platform) }
    func stop() {}
    func setPlayback(_ on: Bool) {}
}

/// Plays nothing.
@MainActor
final class UnsupportedConversationSpeaker: ConversationSpeaker {
    var platform = PlatformName.current

    init() {}

    func say(_ text: String) async throws { throw CapabilityError.unsupported(capability: "ConversationSpeaker", platform: platform) }
    func stop() {}
}

@MainActor
final class UnsupportedClipPlayer: ClipPlaying {
    let platform: String

    init(platform: String) { self.platform = platform }

    func play(_ audio: Data) async throws { throw CapabilityError.unsupported(capability: "ClipPlaying", platform: platform) }
    func stop() {}
}
