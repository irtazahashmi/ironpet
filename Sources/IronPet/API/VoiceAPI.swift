import Foundation
#if canImport(Combine)
import Combine
#endif

struct SpeakRequest: Codable, Equatable {
    /// The reply as markdown. Only its prose is spoken: code, tables and emoji are skipped.
    var text: String
    /// The chat message being read, so its speaker button shows Stop.
    var item: UUID?
}

/// One piece of a spoken reply. A client that is not this Mac plays the chunks in order itself.
struct SpeechChunk: Codable, Equatable {
    var index: Int
    var count: Int
    var mime: String
    var audio: Data
}

struct TranscribeRequest: Codable, Equatable {
    var audio: Data
    var fileName = "audio.wav"
    var mime = "audio/wav"
}

struct VoiceStatus: Codable, Equatable {
    /// Every reply is read aloud automatically (`speech.enabled`).
    var speechEnabled: Bool
    /// A speech model is set, so the speaker button can read a reply.
    var canSpeak: Bool
    /// Voice notes and dictation are switched on in settings.
    var transcriptionEnabled: Bool
    /// The Mac's speaker is reading something now.
    var speaking: Bool
}

/// Speak, stop and transcribe. Speaking either plays on this Mac's speaker (`speak`) or hands the audio to the caller (`audio`),
/// so a remote client can play it on its own. Both use the voice server in Settings → Voice.
@MainActor
final class VoiceAPI {
    /// Fires before the speaker or the settings it reads change.
    let changes = ChangeSignal()
    private let speech: SpeechOutput
    private let settings: SettingsAPI

    /// Text to audio. Tests replace it; the default asks the voice server.
    lazy var synthesize: (String) async throws -> Data = { [weak self] in try await Synthesizer.saved(voiceKey: self?.voiceKey ?? .unsupported).speak($0) }
    /// Audio to text. Tests replace it; the default posts to the voice server.
    lazy var transcribeAudio: @Sendable (Data, String, String) async throws -> String = { [weak self] audio, name, mime in
        let voice = await MainActor.run { SettingsAPI.live.config.voice }
        let key = await MainActor.run { [weak self] in self?.voiceKey ?? .unsupported }
        let transcriber = Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: key.load(), usageFeature: .voiceTranscription)
        // Decodes formats the server may not read (Telegram's Opus voice notes) when macOS can, and sends the rest as they are.
        let transcoder = await MainActor.run { [weak self] in self?.transcoder ?? UnsupportedAudioTranscoder() }
        return try await TelegramVoice.transcribe(audio, name: name, with: transcriber, transcoder: transcoder)
    }

    /// Decodes audio before it is sent. `AppDelegate` sets the Mac one.
    var transcoder: AudioTranscoder = UnsupportedAudioTranscoder()

    /// The voice server's key, which the speaker uses too. `AppDelegate` sets the Mac one.
    var voiceKey = VoiceKey.unsupported {
        didSet { speech.voiceKey = voiceKey }
    }

    private var forwarding: [ChangeToken] = []

    init(speech: SpeechOutput, settings: SettingsAPI) {
        self.speech = speech
        self.settings = settings
        forwarding = [speech.changes.observe { [weak self] in self?.changes.send() }]
        // The player and every client decide from the same settings.
        speech.isEnabled = { [weak settings] in settings?.config.speech.enabled ?? false }
    }

    /// The chat message being read aloud, so its speaker button shows Stop.
    var speakingItem: UUID? { speech.speakingID }

    var status: VoiceStatus {
        VoiceStatus(speechEnabled: settings.config.speech.enabled, canSpeak: settings.config.speech.canSpeak, transcriptionEnabled: settings.config.voice.enabled, speaking: speech.isSpeaking)
    }

    /// Reads a reply aloud on this Mac's speaker. Replaces whatever is being read. It needs a speech model, not the switch for
    /// reading every reply: a press on the speaker button reads with spoken replies off.
    func speak(_ request: SpeakRequest) throws {
        guard settings.config.speech.canSpeak else { throw APIError.unavailable("no speech model is set in Settings") }
        guard !SpeechText.chunks(of: request.text).isEmpty else { throw APIError.invalid("there is nothing to read in that text") }
        do { try speech.speak(request.text, id: request.item ?? UUID()) } catch { throw APIError.unavailable(error.localizedDescription) }
    }

    func stop() { speech.stop() }

    /// The voice names the server offers for the saved speech model. Empty when it has no list.
    func voices() async -> [String] { await Synthesizer.saved(voiceKey: voiceKey).voices() }

    /// Speaks one line with the saved settings even with spoken replies off, so Settings can test the server. Throws what the
    /// server answered, or `CancellationError` when `stop()` or a reply cut it short.
    func preview(_ text: String) async throws {
        try await speech.preview(text, using: Synthesizer.saved(voiceKey: voiceKey))
    }

    /// The audio for a reply, one chunk at a time, without playing anything here. The first chunk is one sentence, so a client
    /// can start playing early.
    func audio(_ request: SpeakRequest) throws -> AsyncThrowingStream<SpeechChunk, Error> {
        guard settings.config.speech.canSpeak else { throw APIError.unavailable("no speech model is set in Settings") }
        let producer = SpeechProducer(synthesize: synthesize)
        let chunks = producer.chunks(of: request.text)
        guard !chunks.isEmpty else { throw APIError.invalid("there is nothing to read in that text") }
        let reader = producer.reader(for: chunks)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    var index = 0
                    while let audio = try await reader.next() {
                        continuation.yield(SpeechChunk(index: index, count: chunks.count, mime: "audio/wav", audio: audio))
                        index += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: (error as? APIError) ?? APIError.failed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in reader.cancel() }
            }
        }
    }

    /// Turns a recording into text with the voice server. It does not touch the microphone.
    func transcribe(_ request: TranscribeRequest) async throws -> String {
        guard settings.config.voice.enabled else { throw APIError.unavailable("voice input is off in Settings") }
        guard !request.audio.isEmpty else { throw APIError.invalid("the audio is empty") }
        do {
            return try await transcribeAudio(request.audio, request.fileName, request.mime)
        } catch {
            throw APIError.failed(error.localizedDescription)
        }
    }
}

#if canImport(Combine)

extension VoiceAPI: ObservableObject {
    nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
