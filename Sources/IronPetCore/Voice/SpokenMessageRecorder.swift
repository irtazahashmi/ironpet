import Foundation
import IronPetKit

/// Records one spoken message for the primary chat. The voice shortcut starts listening. Utterances the microphone cuts at
/// short pauses are collected into one message, which ends after `endPauseSeconds` without speech or on a second press of
/// the shortcut. Nothing said for `silenceSeconds` ends listening. The utterances are transcribed, joined and handed to
/// `onMessage`, which sends them to the chat like typed text. Esc discards them.
@MainActor
package final class SpokenMessageRecorder: ObservableObject {
    package enum State: String { case idle, listening, transcribing }

    @Published package private(set) var state: State = .idle
    /// The last transcribed message, for the pill.
    @Published package private(set) var heard: String?

    /// Listening gives up after this long without speech. `Config.voiceMode.silenceSeconds` in the app.
    package var silenceSeconds: () -> TimeInterval = { TimeInterval(ConfigStore.shared.config.voiceMode.silenceSeconds) }
    /// After something was said, the pause that ends the message. `Config.voiceMode.endPauseSeconds` in the app.
    package var endPauseSeconds: () -> TimeInterval = { ConfigStore.shared.config.voiceMode.endPauseSeconds }
    /// Waits out the silence. Tests replace it so listening does not depend on the wall clock.
    package var silenceSleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    /// Why the pet must not listen right now ("a call", "a meeting recording"), or nil.
    package var quietReason: () -> String? = { nil }
    /// Whether the microphone may be used. The Mac one asks the system.
    package var microphoneAllowed: () async -> Bool = { false }
    package var makeMic: () -> ConversationListening = { UnsupportedConversationMic() }
    /// The voice server's key. The app passes the Keychain one.
    package var voiceKey = VoiceKey.unsupported
    package lazy var transcribe: (Data) async throws -> String = { [weak self] wav in
        let voice = ConfigStore.shared.config.voice
        return try await Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: self?.voiceKey.load(), timeout: 30,
                                     usageFeature: .voiceTranscription).transcribe(wav: wav)
    }
    /// The transcribed message, to send to the chat.
    package var onMessage: (String) -> Void = { _ in }
    package var onStarted: () -> Void = {}
    package var onEnded: () -> Void = {}
    /// Something went wrong that the user should see in a bubble.
    package var onFailure: (String) -> Void = { _ in }
    package var quietCheckInterval: TimeInterval = 2

    package private(set) var mic: ConversationListening?
    private var work: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var endPause: Task<Void, Never>?
    /// The utterances of the message so far, in order.
    private var utterances: [Data] = []
    /// A second press cut the utterance in progress: the message is sent as soon as it arrives.
    private var sendOnUtterance = false
    private var quietWatch: Task<Void, Never>?
    /// Bumped by every end, so a transcription that was overtaken drops its result.
    private var generation = 0
    private var starting = false
    private var endRequested = false
    private var userSpeaking = false
    private let idleLevels = LevelBuffer()

    package init() {}

    package var isActive: Bool { state != .idle || starting }
    package var levels: LevelBuffer { mic?.levels ?? idleLevels }

    package var mood: PetMood? {
        switch state {
        case .idle: return nil
        case .listening: return .attentive
        case .transcribing: return .working
        }
    }

    /// The voice shortcut: starts listening, or sends what has been said so far. With nothing said yet it ends listening.
    package func press() {
        switch state {
        case .idle:
            start()
        case .listening:
            if userSpeaking {
                sendOnUtterance = true
                mic?.cutNow()
            } else if utterances.isEmpty {
                cancel()
            } else {
                send()
            }
        case .transcribing:
            break
        }
    }

    package func start() {
        guard !isActive else { return }
        if let reason = quietReason() { return onFailure("Voice doesn't listen during \(reason).") }
        starting = true
        endRequested = false
        Task { [weak self] in
            guard let self else { return }
            defer { starting = false }
            guard await microphoneAllowed() else {
                return onFailure("ironpet can't use the microphone. Allow it under System Settings → Privacy & Security → Microphone, then try again.")
            }
            guard !endRequested else { return }
            let opened = makeMic()
            opened.onEvent = { [weak self] event in self?.micEvent(event) }
            do {
                try opened.start()
            } catch {
                return onFailure("Could not open the microphone: \(error.localizedDescription)")
            }
            guard !endRequested else { return opened.stop() }
            mic = opened
            heard = nil
            userSpeaking = false
            utterances = []
            sendOnUtterance = false
            state = .listening
            armSilence()
            watchQuiet()
            onStarted()
        }
    }

    /// Stops listening or transcribing and drops the message.
    package func cancel() {
        if starting { endRequested = true }
        guard state != .idle else { return }
        generation += 1
        work?.cancel()
        work = nil
        finish()
    }

    /// `--test-mode`: an utterance as if the microphone had just cut it.
    package func hear(_ audio: Data) {
        micEvent(.speechStarted)
        micEvent(.utterance(audio))
    }

    /// Shows a state for preview renders. Nothing listens or runs.
    package func loadPreview(state: State, heard: String? = nil) {
        self.state = state
        self.heard = heard
    }

    private func finish() {
        silence?.cancel()
        endPause?.cancel()
        quietWatch?.cancel()
        mic?.stop()
        mic = nil
        userSpeaking = false
        utterances = []
        sendOnUtterance = false
        state = .idle
        onEnded()
    }

    private func micEvent(_ event: ConversationMicEvent) {
        guard state == .listening else { return }
        switch event {
        case .speechStarted:
            userSpeaking = true
            silence?.cancel()
            endPause?.cancel()
        case .utterance(let wav):
            userSpeaking = false
            utterances.append(wav)
            if sendOnUtterance { send() } else { armEndPause() }
        case .discarded:
            userSpeaking = false
            let sendNow = sendOnUtterance
            sendOnUtterance = false
            if utterances.isEmpty { armSilence() } else if sendNow { send() } else { armEndPause() }
        case .failed(let message):
            onFailure(message)
            cancel()
        }
    }

    private func send() {
        silence?.cancel()
        endPause?.cancel()
        let clips = utterances
        utterances = []
        sendOnUtterance = false
        // The microphone closes now: the message is complete, and nothing more is heard while it is transcribed.
        mic?.stop()
        mic = nil
        state = .transcribing
        let current = generation
        work = Task { [weak self] in
            guard let self else { return }
            var parts: [String] = []
            do {
                for wav in clips {
                    let part = try await transcribe(wav).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty { parts.append(part) }
                }
            } catch is CancellationError {
                return
            } catch {
                guard current == generation else { return }
                onFailure("Could not transcribe what you said: \(error.localizedDescription)")
                return finish()
            }
            guard current == generation else { return }
            work = nil
            let text = parts.joined(separator: " ")
            guard !text.isEmpty else {
                onFailure("I didn't catch that.")
                return finish()
            }
            heard = text
            finish()
            onMessage(text)
        }
    }

    private func armSilence() {
        silence?.cancel()
        let seconds = silenceSeconds()
        let sleep = silenceSleep
        silence = Task { [weak self] in
            try? await sleep(seconds)
            guard let self, !Task.isCancelled, state == .listening, !userSpeaking else { return }
            cancel()
        }
    }

    private func armEndPause() {
        endPause?.cancel()
        let seconds = endPauseSeconds()
        let sleep = silenceSleep
        endPause = Task { [weak self] in
            try? await sleep(seconds)
            guard let self, !Task.isCancelled, state == .listening, !userSpeaking, !utterances.isEmpty else { return }
            send()
        }
    }

    /// Stops listening when a call or a meeting recording starts.
    private func watchQuiet() {
        quietWatch?.cancel()
        let interval = quietCheckInterval
        quietWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled, state != .idle else { return }
                if let reason = quietReason() {
                    onFailure("Stopped listening: \(reason) started.")
                    return cancel()
                }
            }
        }
    }
}
