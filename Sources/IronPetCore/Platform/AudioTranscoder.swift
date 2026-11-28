import Foundation

/// Decodes an audio file into 16 kHz mono 16-bit WAV, the format the voice server reads best. The Mac adapter is
/// `MacAudioTranscoder`, which uses AVFoundation. `TelegramVoice` sends the original file when the transcoder cannot decode it.
package protocol AudioTranscoder: Sendable {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    var isSupported: Bool { get }
    /// The WAV for `file`, or nil when it cannot be decoded or is longer than `maxSeconds`. Throws
    /// `CapabilityError.unsupported` where nothing can decode audio.
    func wav(from file: URL, maxSeconds: Double) throws -> Data?
    /// The length of the audio in seconds, or nil when the file cannot be read as audio.
    func duration(of file: URL) -> Double?
    /// Decodes `file` to 16 kHz mono samples and hands them to `body` in order, a block at a time. False when it cannot be decoded.
    func stream(from file: URL, body: ([Int16]) throws -> Void) throws -> Bool
}

extension AudioTranscoder {
    package var isSupported: Bool { true }

    /// Nil unless the adapter can read a file's length without decoding it. A meeting import refuses a file whose length
    /// is nil, because it cannot tell whether the file is audio.
    package func duration(of file: URL) -> Double? { nil }

    /// Hands the decoded samples to `body` in order, a block at a time, so a long file never sits in memory whole.
    /// False when the file cannot be decoded. This default decodes the whole file with `wav(from:maxSeconds:)` first.
    package func stream(from file: URL, body: ([Int16]) throws -> Void) throws -> Bool {
        guard let wav = try wav(from: file, maxSeconds: .infinity) else { return false }
        let samples = WAV.samples(of: wav)
        let block = WAV.sampleRate * 30
        var start = 0
        while start < samples.count {
            try body(Array(samples[start..<min(start + block, samples.count)]))
            start += block
        }
        return !samples.isEmpty
    }
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
