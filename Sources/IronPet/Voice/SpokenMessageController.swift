import AppKit
import Carbon
import Combine
import IronPetCore
import IronPetKit

/// Spoken messages in the app: the shortcut starts a conversation. Each utterance goes to the primary chat as a message the
/// user said aloud, and the pet listens again once the reply is written and read. Esc or the pill's button ends it, a pill by
/// the pet shows the microphone, and jobs started during a spoken turn say aloud when they are done.
@MainActor
final class SpokenMessageController {
    let recorder = SpokenMessageRecorder()

    /// The pet's frame, to place the pill next to it.
    var petFrame: () -> CGRect = { .zero }
    /// True while the user has been away from the Mac long enough that a spoken update would go unheard.
    var isAway: () -> Bool = { false }
    /// Sends the transcribed text to the active agent's chat as a spoken message.
    var send: (String) -> Void = { _ in }
    /// Stops what the pet is saying and reports whether it was saying something, so the shortcut can cut in.
    var interruptSpeech: () -> Bool = { false }
    /// Why the pet must not talk or listen now ("a call", "a meeting recording"), or nil.
    var quietReason: () -> String? = { nil } {
        didSet { recorder.quietReason = quietReason }
    }
    /// Whether the chat is writing a reply that is read aloud, so a job that starts now gets its updates said.
    var spokenTurnRunning: () -> Bool = { false }
    var onStateChange: () -> Void = {}

    private lazy var pill = VoicePillPanel(recorder: recorder, petName: { ConfigStore.shared.config.pet.name },
                                           onEnd: { [weak self] in self?.recorder.cancel() })
    private var escape: HotKey?
    private let updates: SpeechPlayer = {
        let player = SpeechPlayer()
        player.isEnabled = { true }
        return player
    }()
    /// Jobs that started while a spoken turn ran, with the state each was last seen in, so one change is said once.
    private var announced: [String: JobState] = [:]
    private var cancellables: Set<AnyCancellable> = []

    static let escapeHotKeyID: UInt32 = 11

    /// The voice server's key. `AppDelegate` sets the Mac one.
    var voiceKey = VoiceKey.unsupported {
        didSet {
            recorder.voiceKey = voiceKey
            updates.voiceKey = voiceKey
        }
    }

    init() {
        recorder.microphoneAllowed = { await VoiceController.microphoneAllowed() }
        recorder.makeMic = { ConversationMic() }
        recorder.onStarted = { [weak self] in self?.started() }
        recorder.onEnded = { [weak self] in self?.ended() }
        recorder.onMessage = { [weak self] text in self?.send(text) }
        recorder.$state
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.onStateChange() } }
            .store(in: &cancellables)
    }

    /// The spoken-message shortcut to register: nil when voice notes are off, because the message is transcribed with the same
    /// server, or the shortcut is cleared.
    nonisolated static func hotkey(in config: Config) -> String? {
        guard config.voice.enabled, !config.hotkeys.voiceMode.isEmpty else { return nil }
        return config.hotkeys.voiceMode
    }

    /// The shortcut: starts listening, sends what has been said, or, while the pet is speaking, stops it and listens.
    func press() {
        if !recorder.isActive || recorder.state == .waiting, interruptSpeech() {
            VoiceTiming.log("talk key: interrupted speech")
        }
        recorder.press()
    }

    private func started() {
        escape = HotKey(keyCode: kVK_Escape, modifiers: 0, id: Self.escapeHotKeyID) { [weak self] in
            MainActor.assumeIsolated { self?.recorder.cancel() }
        }
        pill.present(near: petFrame())
    }

    /// The chat finished the turn of a spoken message, or failed or was stopped.
    func turnEnded(failed: Bool) { recorder.turnEnded(failed: failed) }

    /// The speaker's state changed. Listening resumes once it is quiet.
    func speechChanged() { recorder.speechEnded() }

    private func ended() {
        escape = nil
        pill.dismiss()
    }

    // MARK: Job updates

    /// A job changed. A job that starts while a spoken reply is being written says when it is done, failed or needs an OK,
    /// unless Speak replies is Never, a call or meeting is on, or the user is away. Its bubble shows either way.
    func jobChanged(_ job: Job) {
        guard announced[job.id] != nil || spokenTurnRunning() else { return }
        let previous = announced.updateValue(job.state, forKey: job.id)
        let config = ConfigStore.shared.config
        guard config.voiceMode.speakJobUpdates, config.speech.speakReplies != .never, [.done, .failed, .needsApproval].contains(job.state),
              previous != job.state, quietReason() == nil, !isAway(), let line = Self.update(for: job) else { return }
        let updates = updates
        Task { try? await updates.say(line) }
    }

    nonisolated static func update(for job: Job) -> String? {
        switch job.state {
        case .done:
            return "\(job.title) is done." + (job.summary.map { " \($0)" } ?? "")
        case .failed:
            return "\(job.title) didn't work." + (job.error.flatMap { AgentSession.firstSentence($0) }.map { " \($0)" } ?? "")
        case .needsApproval:
            let what = job.waitingFor.map { " to \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? ""
            return "\(job.title) needs your OK\(what). Click Allow in its bubble."
        default:
            return nil
        }
    }

    // MARK: Test mode

    /// `--test-mode`: no microphone and no speech server. Utterances come from `/test/voice-mode/utterance`, and the
    /// transcript is the bytes sent.
    func useTestDoubles() {
        recorder.makeMic = { SilentMic() }
        recorder.microphoneAllowed = { true }
        recorder.transcribe = { wav in String(decoding: wav, as: UTF8.self) }
    }

    func testSnapshot() -> [String: Any] {
        ["ok": true, "state": recorder.state.rawValue, "heard": recorder.heard ?? "", "pill": pill.panel.isVisible]
    }
}

/// The test-mode microphone: it hears nothing; `/test/voice-mode/utterance` speaks for the user.
@MainActor
final class SilentMic: ConversationListening {
    var onEvent: ((ConversationMic.Event) -> Void)?
    let levels = LevelBuffer()
    func start() throws {}
    func stop() {}
    func cutNow() { onEvent?(.discarded) }
}
