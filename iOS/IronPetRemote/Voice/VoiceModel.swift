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

    /// The text of a finished dictation. The chat puts it in the composer when the mode was `draft`.
    @ObservationIgnored var onTranscript: (String, VoiceMode) -> Void = { _, _ in }

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
    @ObservationIgnored private var reconnect: Task<Void, Never>?

    init(player: ReplyPlayer, defaults: UserDefaults = .standard, openChannel: @escaping () -> any VoiceChannel, makeMic: @escaping () -> any MicSource) {
        self.player = player
        self.defaults = defaults
        self.openChannel = openChannel
        self.makeMic = makeMic
        spokenReplies = defaults.bool(forKey: Self.spokenRepliesKey)
        sendAtOnce = defaults.bool(forKey: Self.sendKey)
        player.onChange = { [weak self] in self?.speaking = self?.player.isBusy ?? false }
        player.onError = { [weak self] in self?.errorMessage = $0 }
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
        let id = UUID().uuidString.lowercased()
        mic = source
        streamID = id
        streamMode = sendAtOnce ? .send : .draft
        state = .recording
        do { try await channel.send(text: VoiceClientMessage.start(id: id, mode: streamMode).json) } catch {
            fail("The Mac is not reachable.")
            return
        }
        pump = Task { [weak self] in
            var framer = VoiceFramer()
            for await pcm in audio {
                for frame in framer.append(pcm) {
                    do { try await channel.send(binary: frame) } catch { self?.fail("The Mac is not reachable."); return framer }
                }
            }
            return framer
        }
    }

    private func endRecording() async {
        guard let id = streamID, let channel else { return }
        mic?.stop()
        mic = nil
        state = .transcribing
        var framer = await pump?.value ?? VoiceFramer()
        pump = nil
        if let last = framer.flush() { try? await channel.send(binary: last) }
        await send(.end(id: id))
    }

    /// Cuts the reply that plays or arrives. The player stops before `tts.stop` goes out.
    func stopSpeaking() async {
        guard player.isBusy else { return }
        player.stop()
        await send(.ttsStop)
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
        if state != .idle {
            mic?.stop()
            mic = nil
            pump?.cancel()
            pump = nil
            streamID = nil
            state = .idle
            errorMessage = "The connection to the Mac closed."
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
                streamID = nil
                state = .idle
                if !text.isEmpty { onTranscript(text, streamMode) }
            case .error(let id, let message):
                errorMessage = message
                if let id, id == streamID {
                    streamID = nil
                    state = .idle
                }
            case .ttsChunk(let reply, _, _):
                announcedReply = reply
                player.receive(reply: reply)
            case .ttsEnd(let reply):
                player.finish(reply: reply)
            }
        case .binary(let data):
            guard let clip = VoiceWire.parseTTSFrame(data), let reply = announcedReply else { return }
            player.add(reply: reply, wav: clip.wav)
        }
    }
}
