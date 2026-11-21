import Foundation

/// Decodes an audio file into 16 kHz mono 16-bit WAV, the format the voice server reads best. The Mac adapter is
/// `MacAudioTranscoder`, which uses AVFoundation. `TelegramVoice` sends the original file when the transcoder cannot decode it.
protocol AudioTranscoder: Sendable {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    var isSupported: Bool { get }
    /// The WAV for `file`, or nil when it cannot be decoded or is longer than `maxSeconds`. Throws
    /// `CapabilityError.unsupported` where nothing can decode audio.
    func wav(from file: URL, maxSeconds: Double) throws -> Data?
}

extension AudioTranscoder {
    var isSupported: Bool { true }
}

/// Decodes nothing.
struct UnsupportedAudioTranscoder: AudioTranscoder {
    var platform = PlatformName.current
    var isSupported: Bool { false }

    init() {}

    func wav(from file: URL, maxSeconds: Double) throws -> Data? {
        throw CapabilityError.unsupported(capability: "AudioTranscoder", platform: platform)
    }
}
