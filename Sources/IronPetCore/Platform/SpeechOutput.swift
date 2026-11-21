import Foundation

/// The speaker side of reading a reply aloud: it turns text into audio with the voice server and plays it on this machine.
/// `SpeechProducer` is the other half and plays nothing, so a client that is not this Mac takes the chunks from it and plays them
/// itself. The Mac adapter is `SpeechPlayer`.
@MainActor
package protocol SpeechOutput: AnyObject {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    nonisolated var isSupported: Bool { get }
    /// Fires before the speaker's state changes.
    var changes: ChangeSignal { get }
    /// The chat item being read, so its speaker button shows Stop.
    var speakingID: UUID? { get }
    var isSpeaking: Bool { get }
    /// Whether every reply is read aloud. `VoiceAPI` points it at the settings.
    var isEnabled: () -> Bool { get set }
    /// A failed request, shown in the chat. Not called for a stop.
    var onFailure: ((String) -> Void)? { get set }
    /// The voice server's key.
    var voiceKey: VoiceKey { get set }

    /// Reads a reply's prose and replaces whatever is being read. Throws `CapabilityError.unsupported` where nothing can play.
    func speak(_ markdown: String, id: UUID) throws
    func stop()
    /// Speaks one line with `synthesizer` regardless of the switch. Throws what the server answered, or `CancellationError`.
    func preview(_ text: String, using synthesizer: Synthesizer) async throws
}

extension SpeechOutput {
    package nonisolated var isSupported: Bool { true }
}

/// Plays nothing.
@MainActor
package final class UnsupportedSpeechOutput: SpeechOutput {
    package var platform = PlatformName.current
    package nonisolated var isSupported: Bool { false }
    package let changes = ChangeSignal()
    package var speakingID: UUID? { nil }
    package var isSpeaking: Bool { false }
    package var isEnabled: () -> Bool = { false }
    package var onFailure: ((String) -> Void)?
    package var voiceKey = VoiceKey.unsupported

    package init() {}

    private var error: CapabilityError { .unsupported(capability: "SpeechOutput", platform: platform) }

    package func speak(_ markdown: String, id: UUID) throws { throw error }
    package func stop() {}
    package func preview(_ text: String, using synthesizer: Synthesizer) async throws { throw error }
}

extension Synthesizer {
    /// The synthesizer for the saved settings: the voice server's URL and key with the speech model and voice.
    @MainActor
    package static func saved(voiceKey: VoiceKey, model: String? = nil, voice: String? = nil) -> Synthesizer {
        let config = ConfigStore.shared.config
        return Synthesizer(baseURL: config.voice.baseUrl, model: model ?? config.speech.model,
                           voice: voice ?? config.speech.voice, speed: config.speech.speed, apiKey: voiceKey.load())
    }
}
