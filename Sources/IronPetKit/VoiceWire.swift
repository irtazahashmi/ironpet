import Foundation

/// How the phone chooses to use a transcript: `draft` puts the text in the composer, `send` sends it as a chat message.
public enum VoiceMode: String, Sendable, Equatable {
    case draft, send
}

/// Messages the phone sends on `/v1/voice`, besides the binary audio frames.
public enum VoiceClientMessage: Equatable, Sendable {
    case start(id: String, mode: VoiceMode)
    case end(id: String)
    case cancel(id: String)
    /// Stops the reply audio that is being made or queued.
    case ttsStop
    /// Reads one reply of the open chat aloud, whether or not spoken replies are on. `item` is the chat message id, and the Mac
    /// answers with `tts.chunk` and `tts.end` whose `reply` is that same id. An older Mac ignores it.
    case ttsSpeak(item: String)
    /// Turns spoken replies on or off for this socket. They are off until the phone turns them on.
    case ttsEnable(Bool)

    public var json: String {
        switch self {
        case .start(let id, let mode):
            return VoiceWire.encode(["type": "voice.start", "id": id, "format": VoiceWire.format, "rate": VoiceWire.sampleRate,
                                     "channels": 1, "mode": mode.rawValue])
        case .end(let id): return VoiceWire.encode(["type": "voice.end", "id": id])
        case .cancel(let id): return VoiceWire.encode(["type": "voice.cancel", "id": id])
        case .ttsStop: return VoiceWire.encode(["type": "tts.stop"])
        case .ttsEnable(let on): return VoiceWire.encode(["type": "tts.enable", "enabled": on])
        case .ttsSpeak(let item): return VoiceWire.encode(["type": "tts.speak", "item": item])
        }
    }

    /// Nil for text that is not a message of the voice protocol.
    public static func parse(_ text: String) -> VoiceClientMessage? {
        guard let object = VoiceWire.decode(text), let type = object["type"] as? String else { return nil }
        let id = object["id"] as? String ?? ""
        switch type {
        case "voice.start":
            guard let mode = (object["mode"] as? String).flatMap(VoiceMode.init(rawValue:)) else { return nil }
            return .start(id: id, mode: mode)
        case "voice.end": return .end(id: id)
        case "voice.cancel": return .cancel(id: id)
        case "tts.stop": return .ttsStop
        case "tts.enable": return .ttsEnable(object["enabled"] as? Bool ?? false)
        case "tts.speak":
            guard let item = object["item"] as? String, !item.isEmpty else { return nil }
            return .ttsSpeak(item: item)
        default: return nil
        }
    }

    /// The audio format a `voice.start` declared, for the Mac to check.
    public static func declaredFormat(_ text: String) -> (format: String, rate: Int, channels: Int)? {
        guard let object = VoiceWire.decode(text) else { return nil }
        return (object["format"] as? String ?? "", object["rate"] as? Int ?? 0, object["channels"] as? Int ?? 0)
    }
}

/// Messages the Mac sends on `/v1/voice`. A `tts.chunk` is followed by one binary frame with its audio.
public enum VoiceServerMessage: Equatable, Sendable {
    case transcript(id: String, text: String)
    case error(id: String?, message: String)
    case ttsChunk(reply: String, index: Int, last: Bool)
    case ttsEnd(reply: String)

    public var json: String {
        switch self {
        case .transcript(let id, let text): return VoiceWire.encode(["type": "voice.transcript", "id": id, "text": text])
        case .error(let id, let message):
            var object: [String: Any] = ["type": "voice.error", "message": message]
            if let id { object["id"] = id }
            return VoiceWire.encode(object)
        case .ttsChunk(let reply, let index, let last): return VoiceWire.encode(["type": "tts.chunk", "reply": reply, "index": index, "last": last])
        case .ttsEnd(let reply): return VoiceWire.encode(["type": "tts.end", "reply": reply])
        }
    }

    public static func parse(_ text: String) -> VoiceServerMessage? {
        guard let object = VoiceWire.decode(text), let type = object["type"] as? String else { return nil }
        switch type {
        case "voice.transcript": return .transcript(id: object["id"] as? String ?? "", text: object["text"] as? String ?? "")
        case "voice.error": return .error(id: object["id"] as? String, message: object["message"] as? String ?? "Voice failed.")
        case "tts.chunk":
            guard let reply = object["reply"] as? String, let index = object["index"] as? Int else { return nil }
            return .ttsChunk(reply: reply, index: index, last: object["last"] as? Bool ?? false)
        case "tts.end": return .ttsEnd(reply: object["reply"] as? String ?? "")
        default: return nil
        }
    }
}

/// The framing of the voice socket (`SPEC.md`, voice streaming). Audio from the phone is 16 kHz mono 16-bit little-endian PCM in
/// frames of 100 ms. Audio from the Mac is one WAV file per chunk.
public enum VoiceWire {
    public static let format = "pcm_s16le"
    public static let sampleRate = 16_000
    public static let frameSamples = 1_600
    /// 100 ms of audio.
    public static let frameBytes = frameSamples * 2
    /// The Mac ends a stream at this many frames, which is five minutes.
    public static let maxFrames = 3_000
    public static let audioFrameType: UInt8 = 0x01
    public static let ttsFrameType: UInt8 = 0x02

    /// `[0x01][4-byte big-endian seq][PCM]`.
    public static func audioFrame(seq: UInt32, pcm: Data) -> Data {
        header(audioFrameType, seq) + pcm
    }

    public static func parseAudioFrame(_ data: Data) -> (seq: UInt32, pcm: Data)? {
        parse(data, type: audioFrameType).map { ($0.number, $0.body) }
    }

    /// `[0x02][4-byte big-endian index][WAV]`.
    public static func ttsFrame(index: UInt32, wav: Data) -> Data {
        header(ttsFrameType, index) + wav
    }

    public static func parseTTSFrame(_ data: Data) -> (index: UInt32, wav: Data)? {
        parse(data, type: ttsFrameType).map { ($0.number, $0.body) }
    }

    private static func header(_ type: UInt8, _ number: UInt32) -> Data {
        Data([type, UInt8(number >> 24 & 0xFF), UInt8(number >> 16 & 0xFF), UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF)])
    }

    private static func parse(_ data: Data, type: UInt8) -> (number: UInt32, body: Data)? {
        let bytes = [UInt8](data.prefix(5))
        guard bytes.count == 5, bytes[0] == type else { return nil }
        let number = bytes[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (number, Data(data.dropFirst(5)))
    }

    static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

/// Cuts a stream of 16-bit samples into frames of 100 ms and numbers them from 0. The rest waits for the next `append`.
public struct VoiceFramer: Sendable {
    private var pending = Data()
    public private(set) var nextSeq: UInt32 = 0

    public init() {}

    /// The whole frames that `pcm` completes, ready to send.
    public mutating func append(_ pcm: Data) -> [Data] {
        pending.append(pcm)
        var frames: [Data] = []
        while pending.count >= VoiceWire.frameBytes {
            frames.append(VoiceWire.audioFrame(seq: nextSeq, pcm: Data(pending.prefix(VoiceWire.frameBytes))))
            pending = Data(pending.dropFirst(VoiceWire.frameBytes))
            nextSeq += 1
        }
        return frames
    }

    /// The last, shorter frame, or nil when the stream ended on a frame boundary.
    public mutating func flush() -> Data? {
        guard !pending.isEmpty else { return nil }
        // A short frame must hold whole samples.
        let usable = pending.prefix(pending.count - pending.count % 2)
        pending = Data()
        guard !usable.isEmpty else { return nil }
        defer { nextSeq += 1 }
        return VoiceWire.audioFrame(seq: nextSeq, pcm: Data(usable))
    }
}
