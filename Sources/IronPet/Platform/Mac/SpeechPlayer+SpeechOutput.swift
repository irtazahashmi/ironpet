import Foundation

/// The Mac adapter for `SpeechOutput` is the speech player, which plays through `AVAudioPlayer`.
extension SpeechPlayer: SpeechOutput {
    nonisolated var isSupported: Bool { true }
}
