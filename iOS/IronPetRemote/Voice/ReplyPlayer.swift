import AVFoundation
import Foundation

/// Plays one WAV clip. `AVAudioPlayer` in the app, a recording fake in tests.
@MainActor
protocol ClipEngine: AnyObject {
    /// Starts the clip and calls `onFinish` when it ends. A clip cut by `stop()` does not call it.
    func play(_ wav: Data, onFinish: @escaping @MainActor () -> Void) throws
    func stop()
    /// Called when a clip that plays dies on its own: it cannot be decoded, or a call or another app interrupts it. `onFinish` is not
    /// called for that clip. The string says what happened and is shown to the user.
    var onFailure: (@MainActor (String) -> Void)? { get set }
}

@MainActor
final class AudioPlayerEngine: NSObject, ClipEngine, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finished: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private var interruption: NSObjectProtocol?

    func play(_ wav: Data, onFinish: @escaping @MainActor () -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let next = try AVAudioPlayer(data: wav)
        next.delegate = self
        finished = onFinish
        player = next
        if interruption == nil {
            interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
                MainActor.assumeIsolated { self?.died("Another app or a call interrupted the reply.") }
            }
        }
        guard next.play() else {
            player = nil
            finished = nil
            throw MicError.unavailable("the clip did not start")
        }
    }

    func stop() {
        finished = nil
        player?.delegate = nil
        player?.stop()
        player = nil
    }

    /// The clip ended without finishing: drop it and tell the player why.
    private func died(_ reason: String) {
        guard player != nil else { return }
        finished = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        onFailure?(reason)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.died("The reply audio could not be played: \(error?.localizedDescription ?? "decoding failed").") }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard flag else { return died("The reply audio stopped before its end.") }
            let done = finished
            finished = nil
            self.player = nil
            done?()
        }
    }
}

/// The clips of a spoken reply, played one after another as they arrive. A stopped reply stays stopped: clips of it that are still
/// on their way are dropped when they arrive.
@MainActor
final class ReplyPlayer {
    private let engine: any ClipEngine
    private var queue: [(reply: String, wav: Data)] = []
    private var playing: String?
    /// The reply the Mac is still sending.
    private var receiving: String?
    private var dropped: Set<String> = []

    /// Called after the state changed, so the screen can show it.
    var onChange: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    init(engine: any ClipEngine) {
        self.engine = engine
        self.engine.onFailure = { [weak self] reason in self?.clipFailed(reason) }
    }

    /// The clip that plays died. The rest of its reply is dropped, so the button returns to Speak and the user sees why.
    private func clipFailed(_ reason: String) {
        guard let reply = playing else { return }
        onError(reason)
        dropped.insert(reply)
        receiving = receiving == reply ? nil : receiving
        queue.removeAll { $0.reply == reply }
        playing = nil
        playNext()
        onChange()
    }

    /// A clip plays, one waits, or the Mac is still sending the reply.
    var isBusy: Bool { playing != nil || !queue.isEmpty || receiving != nil }

    /// The reply that plays, or the next one in line, or the one the Mac is still sending. Nil when nothing is busy.
    var current: String? { playing ?? queue.first?.reply ?? receiving }

    /// The user asked the Mac to read `reply`, which may be one that was stopped before. Its clips are expected now.
    func begin(reply: String) {
        dropped.remove(reply)
        receiving = reply
        onChange()
    }

    /// The Mac announced a clip of `reply`.
    func receive(reply: String) {
        guard !dropped.contains(reply) else { return }
        receiving = reply
        onChange()
    }

    /// A clip of `reply` arrived. Clips of a reply that was stopped are ignored.
    func add(reply: String, wav: Data) {
        guard !dropped.contains(reply) else { return }
        queue.append((reply, wav))
        if playing == nil { playNext() }
        onChange()
    }

    /// The Mac has sent every clip of `reply`.
    func finish(reply: String) {
        if receiving == reply { receiving = nil }
        onChange()
    }

    /// Cuts the clip that plays and drops the queue and the rest of the reply. The model calls this before it tells the Mac to stop.
    func stop() {
        engine.stop()
        for reply in [playing, receiving].compactMap({ $0 }) + queue.map(\.reply) { dropped.insert(reply) }
        queue = []
        playing = nil
        receiving = nil
        onChange()
    }

    private func playNext() {
        guard !queue.isEmpty else {
            playing = nil
            return
        }
        let clip = queue.removeFirst()
        playing = clip.reply
        do {
            try engine.play(clip.wav) { [weak self] in
                guard let self else { return }
                playing = nil
                playNext()
                onChange()
            }
        } catch {
            onError(error.localizedDescription)
            dropped.insert(clip.reply)
            queue.removeAll { $0.reply == clip.reply }
            playing = nil
            playNext()
        }
    }
}
