import Foundation
import IronPetKit

/// The audio of one voice stream from a phone, put back in order. Frames can arrive twice or out of order and can be missing:
/// the first copy of a frame wins, and a missing one becomes 100 ms of silence so the speech keeps its timing.
package struct VoiceStreamBuffer {
    package enum Added: Equatable {
        case stored
        /// A frame with this `seq` is already there.
        case duplicate
        /// The payload is empty, odd in length or longer than 100 ms.
        case malformed
        /// The frame lies past the five minute cap.
        case tooLong
    }

    private var frames: [UInt32: Data] = [:]

    package init() {}

    /// Number of different frames held.
    package var count: Int { frames.count }

    package mutating func add(seq: UInt32, pcm: Data) -> Added {
        guard seq < VoiceWire.maxFrames else { return .tooLong }
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= VoiceWire.frameBytes else { return .malformed }
        guard frames[seq] == nil else { return .duplicate }
        frames[seq] = pcm
        return .stored
    }

    /// The samples from frame 0 to the highest frame seen, and the `seq` of each frame that never arrived.
    package func assemble() -> (samples: [Int16], missing: [UInt32]) {
        guard let last = frames.keys.max() else { return ([], []) }
        var samples: [Int16] = []
        var missing: [UInt32] = []
        samples.reserveCapacity(Int(last + 1) * VoiceWire.frameSamples)
        for seq in 0...last {
            guard let pcm = frames[seq] else {
                missing.append(seq)
                samples.append(contentsOf: repeatElement(0, count: VoiceWire.frameSamples))
                continue
            }
            pcm.withUnsafeBytes { raw in
                for index in 0..<(raw.count / 2) { samples.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) }
            }
            // A short frame in the middle keeps the timing of the frames after it.
            if seq != last, pcm.count < VoiceWire.frameBytes { samples.append(contentsOf: repeatElement(0, count: VoiceWire.frameSamples - pcm.count / 2)) }
        }
        return (samples, missing)
    }
}

/// One phone's voice socket, without the socket: it takes the frames and messages the socket read and hands back what to write.
///
/// Speech to text. The phone sends `voice.start`, binary audio frames and `voice.end`. The Mac turns the frames into a WAV, runs it
/// through the same voice server and silence filter as a voice note, and answers `voice.transcript`. In mode `send` the text also goes
/// into the chat as a message from this device.
///
/// Text to speech. After `tts.enable`, when a turn this device started ends, the reply is synthesized chunk by chunk and written as a
/// `tts.chunk` message followed by its WAV. Nothing plays on this Mac and `isQuiet` is not asked: it guards only the Mac's speaker.
/// `tts.speak` (`item`) reads one message of the open chat the same way, whether or not spoken replies are on, and answers with the
/// message id as the `reply`. Only an assistant message is read, and its text comes from the chat, not from the phone.
/// `tts.stop` drops the reply that is being made.
@MainActor
package final class RemoteVoice {
    package enum Output: Equatable {
        case text(String)
        case binary(Data)
    }

    private struct Stream {
        var id: String
        var mode: VoiceMode
        var buffer = VoiceStreamBuffer()
    }

    private let api: IronPetAPI
    private let device: String
    private let send: (Output) -> Void
    private var stream: Stream?
    private var transcriptions: [UUID: Task<Void, Never>] = [:]
    private var speech: Task<Void, Never>?
    private var spokenReplies = false
    private var unsubscribe: (() -> Void)?

    /// Where gaps and refused frames are noted. The default writes to the system log.
    package var log: (String) -> Void = { NSLog("ironpet: %@", $0) }

    /// Called with a hop name as a voice stream passes each step on the Mac, for timing. The app writes it to the system log with a
    /// time. It gets names only, never audio or text.
    package var hop: (String) -> Void = { _ in }

    package init(api: IronPetAPI, device: String, send: @escaping (Output) -> Void) {
        self.api = api
        self.device = device
        self.send = send
        let origin = ChatOrigin.ios(device: device)
        unsubscribe = api.chat.onTurn { [weak self] sender, event in
            guard sender == origin, case .finished(let answer) = event, let answer else { return }
            self?.turnFinished(answer)
        }
    }

    /// Call when the socket closes. Cancels what is running and forgets the stream.
    package func close() {
        unsubscribe?()
        unsubscribe = nil
        stream = nil
        stopSpeech()
        for task in transcriptions.values { task.cancel() }
        transcriptions = [:]
    }

    // MARK: Input

    package func receive(text: String) {
        guard let message = VoiceClientMessage.parse(text) else { return }
        switch message {
        case .start(let id, let mode):
            guard let declared = VoiceClientMessage.declaredFormat(text), declared.format == VoiceWire.format,
                  declared.rate == VoiceWire.sampleRate, declared.channels == 1 else {
                return fail(id, "Voice needs 16 kHz mono 16-bit PCM.")
            }
            // A new stream replaces one that never ended.
            stream = Stream(id: id, mode: mode)
        case .end(let id):
            guard let finished = stream, id.isEmpty || id == finished.id else { return }
            hop("mac.voice.receive")
            stream = nil
            transcribe(finished)
        case .cancel(let id):
            if let current = stream, id.isEmpty || id == current.id { stream = nil }
        case .ttsStop:
            stopSpeech()
        case .ttsSpeak(let item):
            speakMessage(item)
        case .ttsEnable(let on):
            spokenReplies = on
            if !on { stopSpeech() }
        }
    }

    package func receive(binary: Data) {
        guard let frame = VoiceWire.parseAudioFrame(binary), var current = stream else { return }
        switch current.buffer.add(seq: frame.seq, pcm: frame.pcm) {
        case .stored, .duplicate:
            stream = current
        case .malformed:
            log("voice stream \(current.id): dropped a malformed frame \(frame.seq)")
        case .tooLong:
            stream = nil
            fail(current.id, "A voice message can be five minutes long at most.")
        }
    }

    private func fail(_ id: String?, _ message: String) {
        send(.text(VoiceServerMessage.error(id: id, message: message).json))
    }

    // MARK: Speech to text

    private func transcribe(_ finished: Stream) {
        let (samples, missing) = finished.buffer.assemble()
        if !missing.isEmpty {
            log("voice stream \(finished.id): \(missing.count) frame\(missing.count == 1 ? "" : "s") never arrived (\(missing.prefix(10).map(String.init).joined(separator: ", "))), filled with silence")
        }
        guard !samples.isEmpty else {
            send(.text(VoiceServerMessage.transcript(id: finished.id, text: "").json))
            return
        }
        let wav = WAV.encode(samples)
        let key = UUID()
        transcriptions[key] = Task { [weak self] in
            guard let self else { return }
            defer { transcriptions[key] = nil }
            do {
                hop("mac.voice.transcribe.start")
                let text = try await api.voice.transcribe(TranscribeRequest(audio: wav, fileName: "voice-note.wav")).trimmingCharacters(in: .whitespacesAndNewlines)
                hop("mac.voice.transcribe.done")
                guard !Task.isCancelled else { return }
                send(.text(VoiceServerMessage.transcript(id: finished.id, text: text).json))
                hop("mac.voice.transcript")
                guard finished.mode == .send, !text.isEmpty else { return }
                let origin = ChatOrigin.ios(device: device)
                let outcome = try await api.chat.send(SendChatRequest(text: text, origin: origin)).outcome
                hop("mac.voice.item")
                if outcome == .needsFolder {
                    fail(finished.id, "Choose a folder for this chat on the Mac.")
                }
            } catch is CancellationError {
            } catch {
                fail(finished.id, error.localizedDescription)
            }
        }
    }

    // MARK: Text to speech

    private func turnFinished(_ answer: String) {
        guard spokenReplies else { return }
        speak(answer, reply: UUID().uuidString.lowercased())
    }

    /// Reads one assistant message of the open chat. The phone names the message; the text is the chat's own.
    private func speakMessage(_ item: String) {
        guard let id = UUID(uuidString: item) else {
            fail(nil, "That message is not in this chat.")
            send(.text(VoiceServerMessage.ttsEnd(reply: item).json))
            return
        }
        stopSpeech()
        speech = Task { [weak self] in
            guard let self else { return }
            guard let message = try? await api.chat.message(id), case .assistant(let text) = message.kind, !text.isEmpty else {
                guard !Task.isCancelled else { return }
                fail(nil, "That message is not a reply that can be read.")
                send(.text(VoiceServerMessage.ttsEnd(reply: item).json))
                return
            }
            guard !Task.isCancelled else { return }
            await synthesize(text, reply: item)
        }
    }

    private func speak(_ text: String, reply: String) {
        stopSpeech()
        speech = Task { [weak self] in await self?.synthesize(text, reply: reply) }
    }

    private func synthesize(_ text: String, reply: String) async {
        do {
            for try await chunk in try api.voice.audio(SpeakRequest(text: text)) {
                guard !Task.isCancelled else { return }
                send(.text(VoiceServerMessage.ttsChunk(reply: reply, index: chunk.index, last: chunk.index == chunk.count - 1).json))
                send(.binary(VoiceWire.ttsFrame(index: UInt32(chunk.index), wav: chunk.audio)))
            }
            // A stream that a cancel ended looks like a finished one.
            guard !Task.isCancelled else { return }
        } catch is CancellationError {
            return
        } catch {
            fail(nil, error.localizedDescription)
        }
        send(.text(VoiceServerMessage.ttsEnd(reply: reply).json))
    }

    private func stopSpeech() {
        speech?.cancel()
        speech = nil
    }
}
