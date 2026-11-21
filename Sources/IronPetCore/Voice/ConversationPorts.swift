import Foundation

/// What a voice conversation's microphone reports.
package enum ConversationMicEvent: Equatable {
    case speechStarted
    /// One utterance as a 16 kHz mono WAV.
    case utterance(Data)
    /// Something too short to be speech ended.
    case discarded
    case failed(String)
}

/// What `VoiceConversation` needs from the microphone. `ConversationMic` is the Mac one; tests send events by hand.
@MainActor
package protocol ConversationListening: AnyObject {
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
package protocol ConversationSpeaker: AnyObject {
    /// Throws `CancellationError` when `stop()` cut it short, or what the speech server answered. Throws
    /// `CapabilityError.unsupported` where nothing can play.
    func say(_ text: String) async throws
    func stop()
}

/// Hears nothing.
@MainActor
package final class UnsupportedConversationMic: ConversationListening {
    package var platform = PlatformName.current
    package var onEvent: ((ConversationMicEvent) -> Void)?
    package let levels = LevelBuffer()
    package var player: ClipPlaying { UnsupportedClipPlayer(platform: platform) }

    package init() {}

    package func start() throws { throw CapabilityError.unsupported(capability: "ConversationListening", platform: platform) }
    package func stop() {}
    package func setPlayback(_ on: Bool) {}
}

/// Plays nothing.
@MainActor
package final class UnsupportedConversationSpeaker: ConversationSpeaker {
    package var platform = PlatformName.current

    package init() {}

    package func say(_ text: String) async throws { throw CapabilityError.unsupported(capability: "ConversationSpeaker", platform: platform) }
    package func stop() {}
}

@MainActor
package final class UnsupportedClipPlayer: ClipPlaying {
    package let platform: String

    package init(platform: String) { self.platform = platform }

    package func play(_ audio: Data) async throws { throw CapabilityError.unsupported(capability: "ClipPlaying", platform: platform) }
    package func stop() {}
}
