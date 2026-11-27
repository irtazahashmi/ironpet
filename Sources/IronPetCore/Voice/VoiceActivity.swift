import Foundation

/// Finds where speech starts and ends in the microphone's loudness, one frame at a time. Loudness is
/// `PCMConverter.level`: 0 at -50 dB and below, 1 at 0 dB. The start threshold sits above the room's noise floor, which
/// it follows while nobody speaks, so a fan or a busy café does not count as talking.
package struct VoiceActivity {
    package init() {}

    package struct Tuning {
        package init(
            startHold: TimeInterval = 0.12,
            minStartLevel: Float = 0.36,
            startMargin: Float = 0.18,
            endDrop: Float = 0.08,
            hangover: TimeInterval = 0.7,
            minSpeech: TimeInterval = 0.3,
            maxUtterance: TimeInterval = 30,
            bargeInLevel: Float = 0.55,
            bargeInHold: TimeInterval = 0.25
        ) {
            self.startHold = startHold
            self.minStartLevel = minStartLevel
            self.startMargin = startMargin
            self.endDrop = endDrop
            self.hangover = hangover
            self.minSpeech = minSpeech
            self.maxUtterance = maxUtterance
            self.bargeInLevel = bargeInLevel
            self.bargeInHold = bargeInHold
        }

        /// Speech starts once the level stays above the start threshold this long.
        package var startHold: TimeInterval = 0.12
        /// The lowest start threshold, about -32 dB.
        package var minStartLevel: Float = 0.36
        /// How far above the noise floor speech must be to start.
        package var startMargin: Float = 0.18
        /// Below this, relative to the start threshold, a frame counts as a pause.
        package var endDrop: Float = 0.08
        /// An utterance ends after this much pause. Shorter pauses are a breath between words.
        package var hangover: TimeInterval = 0.7
        /// Less voiced time than this is a cough or a click and is dropped.
        package var minSpeech: TimeInterval = 0.3
        /// An utterance is cut here even if the talking goes on, so one upload stays small.
        package var maxUtterance: TimeInterval = 30
        /// While the pet speaks, the user must be this loud, for this long, to interrupt. Echo cancellation leaves some
        /// of the pet's own voice in the signal, and it must not interrupt itself.
        package var bargeInLevel: Float = 0.55
        package var bargeInHold: TimeInterval = 0.25
    }

    package enum Event: Equatable {
        case started
        /// The utterance ended; `voiced` is how long it was, without the closing pause.
        case ended(voiced: TimeInterval)
        /// Too short to be speech.
        case discarded
    }

    package var tuning = Tuning()
    /// True while the pet's voice is playing, which raises the bar for speech to start.
    package var playback = false
    package private(set) var isSpeaking = false
    package private(set) var noiseFloor: Float = 0.1
    private var above: TimeInterval = 0
    private var length: TimeInterval = 0
    private var pause: TimeInterval = 0

    package var startLevel: Float {
        let normal = max(tuning.minStartLevel, noiseFloor + tuning.startMargin)
        return playback ? max(normal, tuning.bargeInLevel) : normal
    }

    /// Feeds one frame: its level and how long it lasts. Returns what changed, if anything.
    package mutating func feed(level: Float, duration: TimeInterval) -> Event? {
        if isSpeaking { return continueSpeech(level: level, duration: duration) }
        if level >= startLevel {
            above += duration
            if above >= (playback ? tuning.bargeInHold : tuning.startHold) {
                isSpeaking = true
                length = above
                pause = 0
                above = 0
                return .started
            }
        } else {
            above = 0
            // A slow average that falls faster than it rises, so one loud moment does not lift the floor for long.
            let rate: Float = level < noiseFloor ? 0.05 : 0.005
            noiseFloor += (level - noiseFloor) * rate
        }
        return nil
    }

    private mutating func continueSpeech(level: Float, duration: TimeInterval) -> Event? {
        length += duration
        if level >= startLevel - tuning.endDrop { pause = 0 } else { pause += duration }
        guard pause >= tuning.hangover || length >= tuning.maxUtterance else { return nil }
        let voiced = length - pause
        reset()
        return voiced >= tuning.minSpeech ? .ended(voiced: voiced) : .discarded
    }

    /// Forgets the utterance in progress, keeping the noise floor.
    package mutating func reset() {
        isSpeaking = false
        above = 0
        length = 0
        pause = 0
    }
}

/// Cuts the microphone's stream into utterances: keeps a short lead-in so the first syllable is not lost, collects the
/// samples while `VoiceActivity` says someone is speaking, and hands back a WAV when they stop.
package struct UtteranceCutter {
    package init() {}

    package enum Cut: Equatable {
        case started
        case finished(Data)
        case discarded
    }

    /// Audio kept from before speech was detected: the detector needs `startHold` to be sure.
    package static let leadIn: TimeInterval = 0.35

    package var activity = VoiceActivity()
    private var lead: [Int16] = []
    private var utterance: [Int16] = []

    package var isSpeaking: Bool { activity.isSpeaking }

    package mutating func feed(_ samples: [Int16], level: Float) -> Cut? {
        let duration = Double(samples.count) / Double(WAV.sampleRate)
        let event = activity.feed(level: level, duration: duration)
        if activity.isSpeaking || event != nil && event != .started {
            utterance += samples
        } else {
            lead += samples
            let keep = Int(Self.leadIn * Double(WAV.sampleRate))
            if lead.count > keep { lead.removeFirst(lead.count - keep) }
        }
        switch event {
        case .started:
            utterance = lead + utterance
            lead = []
            return .started
        case .ended:
            defer { utterance = [] }
            return .finished(WAV.encode(utterance))
        case .discarded:
            utterance = []
            return .discarded
        case nil:
            return nil
        }
    }

    /// Ends the utterance in progress now and returns it, or nil when nobody was speaking.
    package mutating func flush() -> Data? {
        guard activity.isSpeaking, !utterance.isEmpty else {
            reset()
            return nil
        }
        let wav = WAV.encode(utterance)
        reset()
        return wav
    }

    /// Drops the utterance in progress, for when listening stops.
    package mutating func reset() {
        activity.reset()
        lead = []
        utterance = []
    }
}
