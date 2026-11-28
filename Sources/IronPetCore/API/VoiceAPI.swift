import Foundation
#if canImport(Combine)
import Combine
#endif

package struct SpeakRequest: Codable, Equatable {
    package init(text: String, item: UUID? = nil) {
        self.text = text
        self.item = item
    }

    /// The reply as markdown. Only its prose is spoken: code, tables and emoji are skipped.
    package var text: String
    /// The chat message being read, so its speaker button shows Stop.
    package var item: UUID?
}

/// One piece of a spoken reply. A client that is not this Mac plays the chunks in order itself.
package struct SpeechChunk: Codable, Equatable {
    package init(index: Int, count: Int, mime: String, audio: Data) {
        self.index = index
        self.count = count
        self.mime = mime
        self.audio = audio
    }

    package var index: Int
    package var count: Int
    package var mime: String
    package var audio: Data
}

package struct TranscribeRequest: Codable, Equatable {
    package init(audio: Data, fileName: String = "audio.wav", mime: String = "audio/wav") {
        self.audio = audio
        self.fileName = fileName
        self.mime = mime
    }

    package var audio: Data
    package var fileName = "audio.wav"
    package var mime = "audio/wav"
}

package struct VoiceStatus: Codable, Equatable {
    package init(speechEnabled: Bool, canSpeak: Bool, transcriptionEnabled: Bool, speaking: Bool) {
        self.speechEnabled = speechEnabled
        self.canSpeak = canSpeak
        self.transcriptionEnabled = transcriptionEnabled
        self.speaking = speaking
    }

    /// Replies are read aloud on their own: Speak replies is not Never (`speech.speakReplies`).
    package var speechEnabled: Bool
    /// A speech model is set, so the speaker button can read a reply.
    package var canSpeak: Bool
    /// Voice notes and dictation are switched on in settings.
    package var transcriptionEnabled: Bool
    /// The Mac's speaker is reading something now.
    package var speaking: Bool
}

/// Speak, stop and transcribe. Speaking either plays on this Mac's speaker (`speak`) or hands the audio to the caller (`audio`),
/// so a remote client can play it on its own. Both use the voice server in Settings → Voice.
@MainActor
package final class VoiceAPI {
    /// Fires before the speaker or the settings it reads change.
    package let changes = ChangeSignal()
    private let speech: SpeechOutput
    private let settings: SettingsAPI

    /// Text to audio. Tests replace it; the default asks the voice server.
    package lazy var synthesize: (String) async throws -> Data = { [weak self] in try await Synthesizer.saved(voiceKey: self?.voiceKey ?? .unsupported).speak($0) }
    /// Audio to text. Tests replace it; the default posts to the voice server.
    package lazy var transcribeAudio: @Sendable (Data, String, String) async throws -> String = { [weak self] audio, name, mime in
        let voice = await MainActor.run { SettingsAPI.live.config.voice }
        let key = await MainActor.run { [weak self] in self?.voiceKey ?? .unsupported }
        let prompt = await MainActor.run { VoiceVocabulary.shared.prompt() }
        let transcriber = Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: key.load(), usageFeature: .voiceTranscription, prompt: prompt)
        // Decodes formats the server may not read (Telegram's Opus voice notes) when macOS can, and sends the rest as they are.
        let transcoder = await MainActor.run { [weak self] in self?.transcoder ?? UnsupportedAudioTranscoder() }
        let text = try await TelegramVoice.transcribe(audio, name: name, with: transcriber, transcoder: transcoder)
        return text.isEmpty ? text : await VoiceVocabulary.shared.correct(text)
    }

    /// Decodes audio before it is sent. `AppDelegate` sets the Mac one.
    package var transcoder: AudioTranscoder = UnsupportedAudioTranscoder()

    /// The voice server's key, which the speaker uses too. `AppDelegate` sets the Mac one.
    package var voiceKey = VoiceKey.unsupported {
        didSet { speech.voiceKey = voiceKey }
    }

    private var forwarding: [ChangeToken] = []

    package init(speech: SpeechOutput, settings: SettingsAPI) {
        self.speech = speech
        self.settings = settings
        forwarding = [speech.changes.observe { [weak self] in self?.changes.send() }]
        // The player and every client decide from the same settings.
        speech.isEnabled = { [weak settings] in (settings?.config.speech.speakReplies ?? .never) != .never }
    }

    /// The chat message being read aloud, so its speaker button shows Stop.
    package var speakingItem: UUID? { speech.speakingID }

    package var status: VoiceStatus {
        VoiceStatus(speechEnabled: settings.config.speech.speakReplies != .never, canSpeak: settings.config.speech.canSpeak, transcriptionEnabled: settings.config.voice.enabled, speaking: speech.isSpeaking)
    }

    /// Reads a reply aloud on this Mac's speaker. Replaces whatever is being read. It needs a speech model, not the switch for
    /// reading every reply: a press on the speaker button reads with spoken replies off.
    package func speak(_ request: SpeakRequest) throws {
        guard settings.config.speech.canSpeak else { throw APIError.unavailable("no speech model is set in Settings") }
        guard !SpeechText.chunks(of: request.text).isEmpty else { throw APIError.invalid("there is nothing to read in that text") }
        do { try speech.speak(request.text, id: request.item ?? UUID()) } catch { throw APIError.unavailable(error.localizedDescription) }
    }

    package func stop() { speech.stop() }

    /// The voice names the server offers for the saved speech model. Empty when it has no list.
    package func voices() async -> [String] { await Synthesizer.saved(voiceKey: voiceKey).voices() }

    /// Speaks one line with the saved settings even with spoken replies off, so Settings can test the server. Throws what the
    /// server answered, or `CancellationError` when `stop()` or a reply cut it short.
    package func preview(_ text: String) async throws {
        try await speech.preview(text, using: Synthesizer.saved(voiceKey: voiceKey))
    }

    /// The audio for a reply, one chunk at a time, without playing anything here. The first chunk is one sentence, so a client
    /// can start playing early.
    package func audio(_ request: SpeakRequest) throws -> AsyncThrowingStream<SpeechChunk, Error> {
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
    package func transcribe(_ request: TranscribeRequest) async throws -> String {
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
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
