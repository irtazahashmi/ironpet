import Foundation

/// Decodes an audio file into 16 kHz mono 16-bit WAV, the format the voice server reads best. The Mac adapter is
/// `MacAudioTranscoder`, which uses AVFoundation. `TelegramVoice` sends the original file when the transcoder cannot decode it.
package protocol AudioTranscoder: Sendable {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    var isSupported: Bool { get }
    /// The WAV for `file`, or nil when it cannot be decoded or is longer than `maxSeconds`. Throws
    /// `CapabilityError.unsupported` where nothing can decode audio.
    func wav(from file: URL, maxSeconds: Double) throws -> Data?
}

extension AudioTranscoder {
    package var isSupported: Bool { true }
}

/// Decodes nothing.
package struct UnsupportedAudioTranscoder: AudioTranscoder {
    package var platform = PlatformName.current
    package var isSupported: Bool { false }

    package init() {}

    package func wav(from file: URL, maxSeconds: Double) throws -> Data? {
        throw CapabilityError.unsupported(capability: "AudioTranscoder", platform: platform)
    }
}
