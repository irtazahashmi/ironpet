import Foundation
import IronPetKit
import Observation

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

    private(set) var state: State = .idle
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
    /// True while a reply plays or arrives.
    private(set) var speaking = false
    /// The id of the chat message that plays or arrives, so its speaker button shows Stop.
    private(set) var readingItem: String?

    /// The text of a finished dictation. The chat puts it in the composer when the mode was `draft`.
    @ObservationIgnored var onTranscript: (String, VoiceMode) -> Void = { _, _ in }

    /// What happens to a voice message sent at once, by the id of its stream. The chat draws it as a pending message.
    enum SendEvent: Equatable {
        /// Stop was tapped. The audio is on its way and the text is not known yet.
        case started(id: String)
        case transcribed(id: String, text: String)
        /// The upload failed, the Mac refused it or did not answer in time. `resend` sends the same audio again.
        case failed(id: String, reason: String)
        /// The Mac heard no speech, so nothing is sent.
        case discarded(id: String)
    }
    @ObservationIgnored var onSend: (SendEvent) -> Void = { _ in }

    @ObservationIgnored let player: ReplyPlayer
    @ObservationIgnored private let openChannel: () -> any VoiceChannel
    @ObservationIgnored private let makeMic: () -> any MicSource
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var channel: (any VoiceChannel)?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var mic: (any MicSource)?
    @ObservationIgnored private var pump: Task<VoiceFramer, Never>?
    @ObservationIgnored private var streamID: String?
    @ObservationIgnored private var streamMode: VoiceMode = .draft
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

    init(player: ReplyPlayer, defaults: UserDefaults = .standard, openChannel: @escaping () -> any VoiceChannel, makeMic: @escaping () -> any MicSource) {
        self.player = player
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

    /// Drops a recording without sending it.
    func cancelRecording() async {
        guard state == .recording else { return }
        mic?.stop()
        mic = nil
        pump?.cancel()
        pump = nil
        if let id = streamID { await send(.cancel(id: id)) }
        streamID = nil
        state = .idle
    }

    private func beginRecording() async {
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
        let id = UUID().uuidString.lowercased()
        mic = source
        streamID = id
        streamMode = sendAtOnce ? .send : .draft
        state = .recording
        do { try await channel.send(text: VoiceClientMessage.start(id: id, mode: streamMode).json) } catch {
            fail("The Mac is not reachable.")
            return
        }
        recorded = []
        pump = Task { [weak self] in
            var framer = VoiceFramer()
            for await pcm in audio {
                for frame in framer.append(pcm) {
                    self?.recorded.append(frame)
                    do { try await channel.send(binary: frame) } catch { self?.fail("The Mac is not reachable."); return framer }
                }
            }
            return framer
        }
    }

    /// The microphone stopped on its own while recording. The Mac is told to drop the stream and the user sees why.
    private func micDied(_ source: any MicSource, _ reason: String) async {
        guard mic === source, state == .recording else { return }
        let id = streamID
        fail(reason)
        if let id { await send(.cancel(id: id)) }
    }

    private func endRecording() async {
        guard let id = streamID, let channel else { return }
        PhoneHopLog.mark("phone.voice.stop")
        mic?.stop()
        mic = nil
        state = .transcribing
        // The chat shows the message before the last frames go out, so Stop answers at once.
        if streamMode == .send { onSend(.started(id: id)) }
        var framer = await pump?.value ?? VoiceFramer()
        pump = nil
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
        guard let channel = ensureChannel() else { return fail("The Mac is not reachable.") }
        PhoneHopLog.mark("phone.voice.upload.start")
        do {
            try await channel.send(text: VoiceClientMessage.start(id: id, mode: .send).json)
            for frame in frames { try await channel.send(binary: frame) }
            try await channel.send(text: VoiceClientMessage.end(id: id).json)
        } catch {
            return fail("The Mac is not reachable.")
        }
        PhoneHopLog.mark("phone.voice.upload.done")
        watchForText(id)
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
        if state == .transcribing, streamMode == .send, let id = streamID {
            onSend(.failed(id: id, reason: "The connection to the Mac closed."))
        }
        for id in awaitingChat { onSend(.failed(id: id, reason: "The connection to the Mac closed.")) }
        awaitingChat = []
        if state != .idle {
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
                if streamMode == .send {
                    retained[id] = nil
                    if text.isEmpty {
                        onSend(.discarded(id: id))
                    } else {
                        awaitingChat.insert(id)
                        onSend(.transcribed(id: id, text: text))
                    }
                }
                if !text.isEmpty { onTranscript(text, streamMode) }
            case .error(let id, let message):
                errorMessage = message
                if let id, awaitingChat.remove(id) != nil { onSend(.failed(id: id, reason: message)) }
                if let id, id == streamID {
                    if state == .transcribing, streamMode == .send { onSend(.failed(id: id, reason: message)) }
                    // The Mac refused or ended the stream. A mic that still runs would keep sending frames nobody reads.
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
