import AVFoundation
import Foundation
import IronPetCore
import IronPetKit

/// The microphone for a spoken message. One `AVAudioEngine` with voice processing on, which also removes echo and noise. Each buffer goes to a serial queue, where an
/// `UtteranceCutter` finds where the user starts and stops talking; only those moments reach the main actor.
@MainActor
final class ConversationMic: ConversationListening {
    typealias Event = ConversationMicEvent

    var onEvent: ((Event) -> Void)?
    let levels = LevelBuffer()

    private let engine = AVAudioEngine()
    /// Nothing plays through it. Voice processing needs an output path to start, and this node and mixer are that path.
    private let playerNode = AVAudioPlayerNode()
    private let voiceMixer = AVAudioMixerNode()
    private let cutting = CuttingState()
    private var observer: NSObjectProtocol?
    private var levelTimer: Timer?
    private var running = false

    func start() throws {
        guard !running else { return }
        try catchingObjCException {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            // Voice processing ducks other apps' audio by default, which would make music drop whenever the mic opens.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // Not through `mainMixerNode`: with voice processing on, the engine then fails to start (-10875). A mixer of
            // its own straight to the output node works.
            if playerNode.engine == nil {
                engine.attach(playerNode)
                engine.attach(voiceMixer)
            }
            engine.connect(playerNode, to: voiceMixer, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            engine.connect(voiceMixer, to: engine.outputNode, format: engine.outputNode.outputFormat(forBus: 0))
        }
        try installTapAndStart()
        running = true
        levels.reset()
        let timer = Timer(timeInterval: LevelBuffer.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.levels.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    private func installTapAndStart() throws {
        let cutting = cutting
        let levels = levels
        let converter = AdaptiveConverter()
        try catchingObjCException {
            let input = engine.inputNode
            // With voice processing on, the input side reads 0 Hz once the graph is built; the node's output is what the
            // tap gets: the processed microphone on channel 0, then reference channels (9 in all on a MacBook).
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noInput }
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                let floats = converter.convert(Self.firstChannel(of: buffer))
                guard !floats.isEmpty else { return }
                let level = PCMConverter.level(of: floats[...])
                levels.record(level)
                cutting.feed(PCMConverter.int16(floats), level: level) { event in
                    Task { @MainActor in self?.onEvent?(event) }
                }
            }
            engine.prepare()
            try engine.start()
        }
    }

    /// Channel 0 alone, so the reference channels are not mixed in and do not dilute the level.
    nonisolated static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let format = buffer.format
        guard format.channelCount > 1, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let source = buffer.floatChannelData?[0],
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let target = copy.floatChannelData?[0] else { return buffer }
        target.update(from: source, count: Int(buffer.frameLength))
        copy.frameLength = buffer.frameLength
        return copy
    }

    /// A device change (headphones plugged in, a Bluetooth headset switching profile) stops the engine. Starts it again on
    /// the new device, dropping the utterance in progress.
    private func restart() {
        guard running else { return }
        try? catchingObjCException { engine.inputNode.removeTap(onBus: 0) }
        try? catchingObjCException { engine.stop() }
        // After the reset on the cutter's queue, so no event from before the change arrives after it.
        cutting.reset { [weak self] in
            Task { @MainActor in self?.onEvent?(.discarded) }
        }
        do {
            try installTapAndStart()
            NSLog("ironpet: conversation microphone restarted after a configuration change")
        } catch {
            NSLog("ironpet: conversation microphone could not restart: \(error.localizedDescription)")
            onEvent?(.failed("The microphone stopped and could not be restarted. Check the input device and try again."))
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        try? catchingObjCException { engine.inputNode.removeTap(onBus: 0) }
        try? catchingObjCException { engine.stop() }
        try? catchingObjCException { try engine.inputNode.setVoiceProcessingEnabled(false) }
        cutting.reset()
    }

    func cutNow() {
        cutting.flush { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        }
    }
}

/// The cutter and its playback flag, used only on their own serial queue.
private final class CuttingState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ironpet.conversation-mic")
    private var cutter = UtteranceCutter()

    func feed(_ samples: [Int16], level: Float, emit: @escaping @Sendable (ConversationMic.Event) -> Void) {
        queue.async {
            switch self.cutter.feed(samples, level: level) {
            case .started: emit(.speechStarted)
            case .finished(let wav): emit(.utterance(wav))
            case .discarded: emit(.discarded)
            case nil: break
            }
        }
    }

    /// Ends the utterance in progress and reports it, or reports that there was none.
    func flush(emit: @escaping @Sendable (ConversationMic.Event) -> Void) {
        queue.async {
            if let wav = self.cutter.flush() { emit(.utterance(wav)) } else { emit(.discarded) }
        }
    }

    func reset(then done: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.cutter.reset()
            done?()
        }
    }
}
