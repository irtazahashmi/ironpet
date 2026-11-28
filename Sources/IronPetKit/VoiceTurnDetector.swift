import Foundation

/// Decides, from the loudness of the microphone, when a spoken message is over. The phone runs it on device in voice mode.
///
/// Loudness is 0...1, the square root of the peak of a PCM chunk. The speech threshold sits above the room's noise floor, which it
/// follows while nobody speaks, so a fan does not count as talking. A pause shorter than `endPause` inside a sentence does not end
/// the message. Nothing said for `silence` ends the turn, not voice mode: the caller starts a new one.
public struct VoiceTurnDetector: Sendable {
    /// Seconds of silence after speech that end a message. The same default as the Mac's `voiceMode.endPauseSeconds`.
    public static let defaultEndPause: TimeInterval = 2.5
    /// Seconds with nothing said that end a turn. Voice mode itself stays on. The same default as the Mac's `voiceMode.silenceSeconds`.
    public static let defaultSilence: TimeInterval = 20

    public enum Action: Equatable, Sendable {
        /// Something was said and the pause after it reached `endPause`.
        case endMessage
        /// Nothing was said for `silence`. The turn ends, voice mode does not.
        case giveUp
    }

    public var endPause: TimeInterval
    public var silence: TimeInterval
    /// The lowest speech threshold.
    public var minLevel: Float = 0.2
    /// How far above the noise floor speech must be.
    public var margin: Float = 0.12
    /// Speech counts once the level stays above the threshold this long.
    public var startHold: TimeInterval = 0.12
    /// Less voiced time than this is a click or a cough and does not start a message.
    public var minSpeech: TimeInterval = 0.3

    public private(set) var hasSpeech = false
    public private(set) var noiseFloor: Float = 0.05
    private var above: TimeInterval = 0
    private var voiced: TimeInterval = 0
    private var quiet: TimeInterval = 0
    private var finished = false

    public init(endPause: TimeInterval = defaultEndPause, silence: TimeInterval = defaultSilence) {
        self.endPause = endPause
        self.silence = silence
    }

    private var threshold: Float { max(minLevel, noiseFloor + margin) }

    /// Feeds one chunk: its loudness and how long it lasts. Returns an action once, then nothing more.
    public mutating func feed(level: Float, duration: TimeInterval) -> Action? {
        guard !finished else { return nil }
        let loud = level >= threshold
        if loud {
            above += duration
            if above >= startHold {
                voiced += duration
                if voiced >= minSpeech { hasSpeech = true }
            }
            if hasSpeech { quiet = 0 }
        } else {
            above = 0
            // A slow average that falls faster than it rises, so one loud moment does not lift the floor for long.
            noiseFloor += (level - noiseFloor) * (level < noiseFloor ? 0.05 : 0.005)
        }
        if !loud { quiet += duration }
        if hasSpeech {
            guard quiet >= endPause else { return nil }
            finished = true
            return .endMessage
        }
        // Before any speech the whole wait counts, even a click that stayed below `minSpeech`.
        guard quiet >= silence else { return nil }
        finished = true
        return .giveUp
    }
}
