import Foundation
import IronPetKit
import Observation
import UIKit

/// The part of `UIApplication` that keeps the screen on. A fake in tests.
@MainActor
protocol IdleTimerControl: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}

extension UIApplication: IdleTimerControl {}

/// Keeps the screen awake while a voice message is recorded or a reply is read aloud, and puts the idle timer back to the value it
/// had before, not to false.
@MainActor
final class ScreenAwake {
    private let app: any IdleTimerControl
    private var previous: Bool?

    init(app: any IdleTimerControl) { self.app = app }

    func set(_ awake: Bool) {
        if awake {
            guard previous == nil else { return }
            previous = app.isIdleTimerDisabled
            app.isIdleTimerDisabled = true
        } else if let value = previous {
            previous = nil
            app.isIdleTimerDisabled = value
        }
    }
}

/// The phone's side of the voice socket: the mic button, the transcript it gets back, and the spoken replies.
///
/// A tap on the mic streams audio to the Mac. A second tap ends the stream, and the Mac answers with the text. With spoken replies on,
/// the Mac sends the audio of each reply this phone asked for, and `ReplyPlayer` plays it. A tap on the mic or typing cuts the reply:
/// the player stops first, then the Mac is told to stop making the rest.
@MainActor @Observable
final class VoiceModel {
    enum State: Equatable {
        case idle
        case recording
        /// The stream ended and the Mac is turning it into text.
        case transcribing
    }

    static let spokenRepliesKey = "voice.spokenReplies"
    static let sendKey = "voice.sendAtOnce"

    private(set) var state: State = .idle { didSet { updateScreenAwake() } }
    var errorMessage: String?
    /// True when `errorMessage` is about microphone permission, so the view offers a way to the Settings app.
    var needsSettings: Bool { errorMessage == MicError.denied.errorDescription }
    /// Whether the Mac sends the audio of replies to this phone. Off until the user turns it on.
    var spokenReplies: Bool {
        didSet {
            guard spokenReplies != oldValue else { return }
            defaults.set(spokenReplies, forKey: Self.spokenRepliesKey)
            Task { await spokenRepliesChanged() }
        }
    }
    /// Whether a dictated message is sent at once instead of landing in the composer.
    var sendAtOnce: Bool {
        didSet { defaults.set(sendAtOnce, forKey: Self.sendKey) }
    }
    /// True from the voice mode tap until the user turns it off. The phone ends each message itself after a pause. Silence only ends
    /// the turn: listening starts again. A message sent, or a reply that finishes, brings it back to listening.
    private(set) var voiceModeOn = false
    /// The pause after speech that ends a voice mode message. Seconds. Shared default with the Mac, `voiceMode.endPauseSeconds`.
    @ObservationIgnored var endPause: TimeInterval = VoiceTurnDetector.defaultEndPause
    /// Seconds with nothing said before voice mode ends. Shared default with the Mac, `voiceMode.silenceSeconds`.
    @ObservationIgnored var silence: TimeInterval = VoiceTurnDetector.defaultSilence
    /// Decides on device when a voice mode message is over. Nil outside voice mode.
    @ObservationIgnored private var turn: VoiceTurnDetector?
    /// When the running recording began. The recording bar counts from it.
    private(set) var startedAt: Date?
    /// Loudness of the running recording, drawn by the waveform. A reference type, so drawing never re-renders the chat.
    @ObservationIgnored let levels = LevelBuffer()
    /// True while a reply plays or arrives.
    private(set) var speaking = false {
        didSet {
            updateScreenAwake()
            // The reply is read out, so the next turn starts.
            if oldValue, !speaking { resumeVoiceMode() }
        }
    }
    /// The id of the chat message that plays or arrives, so its speaker button shows Stop.
    private(set) var readingItem: String?

    /// The text of a finished dictation. The chat puts it in the composer when the mode was `draft`.
    @ObservationIgnored var onTranscript: (String, VoiceMode) -> Void = { _, _ in }

    /// What happens to a voice message sent at once, by the id of its stream. The chat draws it as a pending message.
    enum SendEvent: Equatable {
        /// Stop was tapped. The audio is on its way and the text is not known yet. With `carry` the phone sends the text itself, with
        /// the attachments of the composer, so the message holds them from now on.
        case started(id: String, carry: Bool)
        /// The text of a recording the phone sends itself (`carry`). Nothing is in the chat yet.
        case text(id: String, text: String)
        /// The Mac could not be reached while recording or at Stop. The audio waits on the phone.
        case offline(id: String, audio: Data)
        case transcribed(id: String, text: String)
        /// The upload failed, the Mac refused it or did not answer in time. `resend` sends the same audio again.
        case failed(id: String, reason: String)
        /// The Mac heard no speech, so nothing is sent.
        case discarded(id: String)
    }
    @ObservationIgnored var onSend: (SendEvent) -> Void = { _ in }
    /// True when the composer holds typed text, attachments or a reply quote. A voice message sent at once then carries them, so the phone sends it itself.
    @ObservationIgnored var hasComposerContent: () -> Bool = { false }
    /// True when an earlier message waits to be sent. A voice message recorded now goes behind it, so the Mac sees them in order.
    @ObservationIgnored var hasEarlierMessages: () -> Bool = { false }
    /// The recording as raw PCM, kept to save it when the Mac cannot be reached.
    @ObservationIgnored private var recordedPCM = Data()
    /// The Mac could not be reached since this recording began. The mic keeps recording and nothing more is sent.
    @ObservationIgnored private var offline = false
    /// True for a recording the phone sends itself: the Mac only transcribes it.
    @ObservationIgnored private var carry = false
    /// A saved recording whose text the app waits for.
    /// Streams the phone sends itself, so `resend` asks the Mac only for the text.
    @ObservationIgnored private var carried: Set<String> = []
    @ObservationIgnored private var savedWaiter: CheckedContinuation<SavedTranscript, Never>?

    @ObservationIgnored let player: ReplyPlayer
    @ObservationIgnored private let screen: ScreenAwake
    @ObservationIgnored private let openChannel: () -> any VoiceChannel
    @ObservationIgnored private let makeMic: () -> any MicSource
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var channel: (any VoiceChannel)?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var mic: (any MicSource)?
    @ObservationIgnored private var pump: Task<VoiceFramer, Never>?
    @ObservationIgnored private var streamID: String?
    @ObservationIgnored private var streamMode: VoiceMode = .draft
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var announcedReply: String?
    /// The frames of a recording sent at once, by stream id, kept until the Mac has the text so `resend` can send them again.
    @ObservationIgnored private var retained: [String: [Data]] = [:]
    @ObservationIgnored private var recorded: [Data] = []
    /// Streams whose text is known and whose message the Mac is still putting in the chat. An error for one fails its pending message.
    @ObservationIgnored private var awaitingChat: Set<String> = []
    @ObservationIgnored private var reconnect: Task<Void, Never>?
    /// The message a speaker button asked for, until its first clip or its end arrives.
    @ObservationIgnored private var pendingRead: String?
    @ObservationIgnored private var readTimeout: Task<Void, Never>?

    /// How long the Mac has to start a reply that a speaker button asked for. An older Mac never answers.
    static var readTimeout: Duration = .seconds(20)
    /// How long the Mac has to answer a finished recording with its text before the phone gives up.
    static var transcribeTimeout: Duration = .seconds(30)

    init(player: ReplyPlayer, defaults: UserDefaults = .standard, openChannel: @escaping () -> any VoiceChannel, makeMic: @escaping () -> any MicSource, idleTimer: any IdleTimerControl = UIApplication.shared) {
        self.player = player
        screen = ScreenAwake(app: idleTimer)
        self.defaults = defaults
        self.openChannel = openChannel
        self.makeMic = makeMic
        spokenReplies = defaults.bool(forKey: Self.spokenRepliesKey)
        sendAtOnce = defaults.bool(forKey: Self.sendKey)
        player.onChange = { [weak self] in
            self?.speaking = self?.player.isBusy ?? false
            self?.readingItem = self?.player.current
        }
        // A clip that failed drops the rest of its reply on the phone, so the Mac stops producing it too.
        player.onError = { [weak self] message in
            self?.errorMessage = message
            Task { await self?.send(.ttsStop) }
        }
    }

    /// The screen stays on while the mic records and while a reply plays or arrives. Waiting for the text does not need it.
    private func updateScreenAwake() { screen.set(state == .recording || speaking) }

    /// Connects when spoken replies are on, so the Mac knows to send them. Call when the tabs appear.
    func start() {
        guard spokenReplies else { return }
        _ = ensureChannel()
    }

    /// Closes the socket and the mic. Call when the tabs go away.
    func stop() {
        reconnect?.cancel()
        reconnect = nil
        mic?.stop()
        mic = nil
        pump?.cancel()
        pump = nil
        player.stop()
        listener?.cancel()
        listener = nil
        channel?.close()
        channel = nil
        endVoiceMode()
        state = .idle
    }

    // MARK: Microphone

    /// Starts a recording, or ends the one that runs.
    func micTapped() async {
        switch state {
        case .idle: await beginRecording()
        case .recording: await endRecording()
        case .transcribing: break
        }
    }

    /// Starts voice mode, or ends it without sending anything when it runs. The message is sent when the phone hears the pause.
    func voiceModeTapped() async {
        switch state {
        case .idle: await beginRecording(voiceMode: true)
        default:
            guard voiceModeOn else { return }
            // Turned off while listening, while the message uploads or while the reply plays: nothing partial is sent.
            if state == .recording { await cancelRecording() } else { endVoiceMode() }
        }
    }

    /// Listens again when voice mode is on and nothing else holds the mic.
    private func resumeVoiceMode() {
        guard voiceModeOn, state == .idle, !speaking else { return }
        Task { await beginRecording(voiceMode: true) }
    }

    /// Drops a recording without sending it.
    func cancelRecording(keepVoiceMode: Bool = false) async {
        guard state == .recording else { return }
        if keepVoiceMode { turn = nil } else { endVoiceMode() }
        mic?.stop()
        mic = nil
        pump?.cancel()
        pump = nil
        let id = streamID
        streamID = nil
        state = .idle
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let id { await send(.cancel(id: id)) }
    }

    private func endVoiceMode() {
        voiceModeOn = false
        turn = nil
    }

    private func beginRecording(voiceMode: Bool = false) async {
        errorMessage = nil
        // The reply stops here, on the phone, before the Mac hears about it.
        await stopSpeaking()
        guard let channel = ensureChannel() else { return }
        let source = makeMic()
        let audio: AsyncStream<Data>
        do { audio = try await source.start() } catch {
            errorMessage = error.localizedDescription
            return
        }
        source.onFailure = { [weak self, weak source] reason in
            Task { @MainActor in
                guard let self, let source else { return }
                await self.micDied(source, reason)
            }
        }
        source.onInterrupted = { [weak self, weak source] reason in
            Task { @MainActor in
                guard let self, let source else { return }
                await self.micInterrupted(source, reason)
            }
        }
        let id = UUID().uuidString.lowercased()
        mic = source
        streamID = id
        streamMode = sendAtOnce || voiceMode ? .send : .draft
        voiceModeOn = voiceMode
        turn = voiceMode ? VoiceTurnDetector(endPause: endPause, silence: silence) : nil
        // With content in the composer the phone sends the message itself, so the Mac only turns the audio into text.
        carry = streamMode == .send && hasComposerContent()
        offline = false
        recorded = []
        recordedPCM = Data()
        state = .recording
        startMetering()
        // The Mac hears a message sent at once as a transcript to send (`send`), or as a plain transcript the phone sends (`draft`).
        let wireMode: VoiceMode = carry ? .draft : streamMode
        do { try await channel.send(text: VoiceClientMessage.start(id: id, mode: wireMode).json) } catch {
            // A message sent at once keeps recording without the Mac, and waits on the phone.
            guard streamMode == .send else {
                fail("The Mac is not reachable.")
                return
            }
            offline = true
        }
        let levels = levels
        pump = Task { [weak self] in
            var framer = VoiceFramer()
            for await pcm in audio {
                let level = Self.level(of: pcm)
                levels.record(level)
                self?.listen(level: level, samples: pcm.count / MemoryLayout<Int16>.size)
                self?.recordedPCM.append(pcm)
                for frame in framer.append(pcm) {
                    self?.recorded.append(frame)
                    guard self?.offline != true else { continue }
                    do { try await channel.send(binary: frame) } catch {
                        guard self?.streamMode == .send else { self?.fail("The Mac is not reachable."); return framer }
                        self?.offline = true
                    }
                }
            }
            return framer
        }
    }

    /// Feeds voice mode's detector. A pause after speech sends the message. Silence from the start ends voice mode and drops the stream.
    private func listen(level: Float, samples: Int) {
        guard voiceModeOn, state == .recording, var detector = turn else { return }
        let action = detector.feed(level: level, duration: Double(samples) / Double(VoiceWire.sampleRate))
        turn = detector
        switch action {
        case .endMessage: Task { await endRecording() }
        case .giveUp:
            // Silence ends the turn, not voice mode: the stream is dropped and a new one starts.
            Task {
                await cancelRecording(keepVoiceMode: true)
                resumeVoiceMode()
            }
        case nil: break
        }
    }

    /// Hands the recording to the chat, which keeps it until the Mac is back.
    private func saveOffline(_ id: String) {
        let audio = recordedPCM
        recordedPCM = Data()
        retained[id] = nil
        carried.remove(id)
        streamID = nil
        state = .idle
        offline = false
        onSend(.offline(id: id, audio: audio))
    }

    /// Resets the waveform and ticks it 25 times a second until the recording ends.
    private func startMetering() {
        levels.reset()
        startedAt = Date()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled, self?.state == .recording {
                self?.levels.tick()
                try? await Task.sleep(for: .seconds(LevelBuffer.tickInterval))
            }
        }
    }

    /// The loudest sample of a 16-bit little-endian PCM chunk, 0...1. A square root lifts quiet speech so the bars are visible.
    nonisolated static func level(of pcm: Data) -> Float {
        var peak: Int32 = 0
        pcm.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Int32(Int16(littleEndian: sample)))) }
        }
        return min(1, (Float(peak) / Float(Int16.max)).squareRoot())
    }

    /// The microphone stopped on its own while recording. The Mac is told to drop the stream and the user sees why.
    private func micDied(_ source: any MicSource, _ reason: String) async {
        guard mic === source, state == .recording else { return }
        let id = streamID
        fail(reason)
        if let id { await send(.cancel(id: id)) }
    }

    /// A call or Siri took the microphone while recording. What was recorded before it is sent as usual, and the user sees that the
    /// message was cut short. With nothing recorded yet it is dropped like any other failure.
    private func micInterrupted(_ source: any MicSource, _ reason: String) async {
        guard mic === source, state == .recording else { return }
        guard !recordedPCM.isEmpty else { return await micDied(source, reason) }
        await endRecording()
        if errorMessage == nil { errorMessage = "Cut short: \(reason) What you said before is sent." }
    }

    private func endRecording() async {
        guard let id = streamID, let channel else { return }
        PhoneHopLog.mark("phone.voice.stop")
        turn = nil
        mic?.stop()
        mic = nil
        state = .transcribing
        if carry { carried.insert(id) }
        // The chat shows the message before the last frames go out, so Stop answers at once.
        if streamMode == .send { onSend(.started(id: id, carry: carry)) }
        var framer = await pump?.value ?? VoiceFramer()
        pump = nil
        // The Mac was out of reach, or an earlier message still waits. The recording is saved and sent after it.
        if streamMode == .send, offline || hasEarlierMessages() {
            if !offline { await send(.cancel(id: id)) }
            return saveOffline(id)
        }
        PhoneHopLog.mark("phone.voice.upload.start")
        do {
            let last = framer.flush()
            if let last { recorded.append(last) }
            // Kept before the first send that can fail, so Retry has the audio after any upload error.
            if streamMode == .send { retained[id] = recorded }
            if let last { try await channel.send(binary: last) }
            try await channel.send(text: VoiceClientMessage.end(id: id).json)
        } catch {
            fail("The Mac is not reachable.")
            return
        }
        PhoneHopLog.mark("phone.voice.upload.done")
        watchForText(id)
    }

    private func watchForText(_ id: String) {
        let timeout = Self.transcribeTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, state == .transcribing, streamID == id else { return }
            finishSaved(.failed("The Mac did not send the text back. Try again."))
            fail("The Mac did not send the text back. Try again.")
        }
    }

    /// Sends the audio of a failed voice message again, from the first frame. A second call while the first runs does nothing.
    func resend(_ id: String) async {
        guard state == .idle, let frames = retained[id] else {
            // The pending message is already in the sending state. Without this it would stay there.
            if state == .idle { onSend(.failed(id: id, reason: "The recording is gone. Record it again.")) }
            return
        }
        errorMessage = nil
        // The state changes before the first await, so a second tap finds the model busy.
        state = .transcribing
        streamID = id
        streamMode = .send
        carry = carried.contains(id)
        guard let channel = ensureChannel() else { return fail("The Mac is not reachable.") }
        PhoneHopLog.mark("phone.voice.upload.start")
        do {
            try await channel.send(text: VoiceClientMessage.start(id: id, mode: carry ? .draft : .send).json)
            for frame in frames { try await channel.send(binary: frame) }
            try await channel.send(text: VoiceClientMessage.end(id: id).json)
        } catch {
            return fail("The Mac is not reachable.")
        }
        PhoneHopLog.mark("phone.voice.upload.done")
        watchForText(id)
    }

    /// Asks the Mac for the text of a recording saved on the phone. Nothing goes in the chat: the app sends the text itself.
    /// Returns `.unreachable` when the Mac cannot be reached or the model is busy with another recording, so the message keeps waiting.
    func transcribeSaved(_ id: String, _ pcm: Data) async -> SavedTranscript {
        guard state == .idle, savedWaiter == nil, let channel = ensureChannel() else { return .unreachable }
        errorMessage = nil
        state = .transcribing
        streamID = id
        streamMode = .draft
        carry = false
        return await withCheckedContinuation { (continuation: CheckedContinuation<SavedTranscript, Never>) in
            savedWaiter = continuation
            Task { [weak self] in
                do {
                    try await channel.send(text: VoiceClientMessage.start(id: id, mode: .draft).json)
                    var framer = VoiceFramer()
                    for frame in framer.append(pcm) { try await channel.send(binary: frame) }
                    if let last = framer.flush() { try await channel.send(binary: last) }
                    try await channel.send(text: VoiceClientMessage.end(id: id).json)
                } catch {
                    self?.finishSaved(.unreachable)
                    self?.resetAfterSaved()
                    return
                }
                self?.watchForText(id)
            }
        }
    }

    private func finishSaved(_ result: SavedTranscript) {
        guard let waiter = savedWaiter else { return }
        savedWaiter = nil
        waiter.resume(returning: result)
    }

    private func resetAfterSaved() {
        streamID = nil
        state = .idle
    }

    /// Cuts the reply that plays or arrives. The player stops before `tts.stop` goes out.
    func stopSpeaking() async {
        guard player.isBusy else { return }
        player.stop()
        await send(.ttsStop)
    }

    /// The speaker button of a reply: reads the message aloud, or stops it when it is the one being read. Works with spoken replies off.
    func toggleReading(_ item: String) async {
        if readingItem == item {
            pendingRead = nil
            await stopSpeaking()
            return
        }
        errorMessage = nil
        // Whatever plays stops on the phone first, as when the mic is tapped.
        await stopSpeaking()
        guard let channel = ensureChannel() else { return }
        player.begin(reply: item)
        pendingRead = item
        readTimeout?.cancel()
        readTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.readTimeout)
            guard !Task.isCancelled, let self, pendingRead == item else { return }
            pendingRead = nil
            player.stop()
            errorMessage = "The Mac did not answer. Update ironpet on the Mac to read replies aloud."
        }
        do { try await channel.send(text: VoiceClientMessage.ttsSpeak(item: item).json) } catch {
            pendingRead = nil
            readTimeout?.cancel()
            player.stop()
            errorMessage = "The Mac is not reachable."
        }
    }

    /// The user typed in the composer. A reply that plays stops at once.
    func userTyped() {
        guard player.isBusy else { return }
        Task { await stopSpeaking() }
    }

    // MARK: Socket

    /// Writes to the socket, opening it first when it is not open.
    private func send(_ message: VoiceClientMessage) async {
        try? await (channel ?? ensureChannel())?.send(text: message.json)
    }

    private func spokenRepliesChanged() async {
        if spokenReplies {
            _ = ensureChannel()
        } else {
            player.stop()
            try? await channel?.send(text: VoiceClientMessage.ttsEnable(false).json)
            if state == .idle {
                listener?.cancel()
                channel?.close()
                channel = nil
            }
        }
    }

    private func ensureChannel() -> (any VoiceChannel)? {
        if let channel { return channel }
        let opened = openChannel()
        channel = opened
        let incoming = opened.incoming()
        let wantsReplies = spokenReplies
        listener = Task { [weak self] in
            if wantsReplies { try? await opened.send(text: VoiceClientMessage.ttsEnable(true).json) }
            do {
                for try await message in incoming { self?.handle(message) }
            } catch {}
            self?.channelClosed(opened)
        }
        return opened
    }

    private func channelClosed(_ closed: any VoiceChannel) {
        guard channel === closed else { return }
        channel = nil
        finishSaved(.unreachable)
        if state == .transcribing, streamMode == .send, let id = streamID {
            onSend(.failed(id: id, reason: "The connection to the Mac closed."))
        }
        for id in awaitingChat { onSend(.failed(id: id, reason: "The connection to the Mac closed.")) }
        awaitingChat = []
        if state != .idle {
            endVoiceMode()
            mic?.stop()
            mic = nil
            pump?.cancel()
            pump = nil
            streamID = nil
            state = .idle
            errorMessage = "The connection to the Mac closed."
        }
        if player.isBusy || pendingRead != nil {
            pendingRead = nil
            readTimeout?.cancel()
            if errorMessage == nil { errorMessage = "The connection to the Mac closed, so the reply stopped." }
        }
        player.stop()
        guard spokenReplies else { return }
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func fail(_ message: String) {
        endVoiceMode()
        if state == .transcribing, streamMode == .send, let id = streamID { onSend(.failed(id: id, reason: message)) }
        mic?.stop()
        mic = nil
        pump?.cancel()
        pump = nil
        streamID = nil
        state = .idle
        errorMessage = message
    }

    func handle(_ message: VoiceInbound) {
        switch message {
        case .text(let text):
            guard let parsed = VoiceServerMessage.parse(text) else { return }
            switch parsed {
            case .transcript(let id, let text):
                guard id == streamID else { return }
                PhoneHopLog.mark("phone.voice.ack")
                streamID = nil
                state = .idle
                if let waiter = savedWaiter {
                    // A saved recording: the app sends the text itself.
                    savedWaiter = nil
                    waiter.resume(returning: text.isEmpty ? .empty : .text(text))
                    return
                }
                if streamMode == .send, carry {
                    retained[id] = nil
                    carried.remove(id)
                    onSend(.text(id: id, text: text))
                } else if streamMode == .send {
                    retained[id] = nil
                    if text.isEmpty {
                        onSend(.discarded(id: id))
                    } else {
                        awaitingChat.insert(id)
                        onSend(.transcribed(id: id, text: text))
                    }
                }
                if !text.isEmpty { onTranscript(text, streamMode) }
                // An empty message, or replies that stay silent: nothing to wait for, so the next turn starts.
                if text.isEmpty || !spokenReplies { resumeVoiceMode() }
            case .error(let id, let message):
                if let waiter = savedWaiter, id == streamID {
                    savedWaiter = nil
                    waiter.resume(returning: .failed(message))
                }
                errorMessage = message
                if let id, awaitingChat.remove(id) != nil { onSend(.failed(id: id, reason: message)) }
                if let id, id == streamID {
                    if state == .transcribing, streamMode == .send { onSend(.failed(id: id, reason: message)) }
                    // The Mac refused or ended the stream. A mic that still runs would keep sending frames nobody reads.
                    endVoiceMode()
                    mic?.stop()
                    mic = nil
                    pump?.cancel()
                    pump = nil
                    streamID = nil
                    state = .idle
                }
            case .ttsChunk(let reply, _, _):
                if pendingRead == reply { pendingRead = nil }
                announcedReply = reply
                player.receive(reply: reply)
            case .ttsEnd(let reply):
                if pendingRead == reply { pendingRead = nil }
                player.finish(reply: reply)
            }
        case .binary(let data):
            guard let clip = VoiceWire.parseTTSFrame(data), let reply = announcedReply else { return }
            player.add(reply: reply, wav: clip.wav)
        }
    }
}
