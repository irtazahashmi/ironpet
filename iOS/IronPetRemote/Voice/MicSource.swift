import AVFoundation
import Foundation

/// A source of microphone audio as 16 kHz mono 16-bit little-endian PCM, in chunks of any size.
protocol MicSource: AnyObject {
    /// Starts capturing. The stream ends after `stop()`, or when a file source runs out of audio.
    func start() async throws -> AsyncStream<Data>
    func stop()
    /// Called once, from any thread, when capture dies on its own after `start()` (a route change, a phone call, a media services reset).
    /// The source has already torn itself down. The string says what happened and is shown to the user.
    var onFailure: (@Sendable (String) -> Void)? { get set }
    /// Called once, from any thread, when a call, Siri or another app takes the microphone while recording. The source has torn itself
    /// down and the audio it captured so far is intact, so the caller sends it. A source that never reports this uses `onFailure`.
    var onInterrupted: (@Sendable (String) -> Void)? { get set }
}

extension MicSource {
    var onInterrupted: (@Sendable (String) -> Void)? {
        get { nil }
        set {}
    }
}

enum MicError: LocalizedError {
    case denied
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .denied: return "IronPet Remote has no access to the microphone. Allow it in Settings."
        case .unavailable(let reason): return "The microphone is not available: \(reason)"
        }
    }
}

/// Converts audio buffers of any format to the format the Mac expects.
final class PCMConverter {
    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(16_000), channels: 1, interleaved: true)!

    private var converter: AVAudioConverter?

    /// The 16 kHz mono 16-bit samples of `buffer`, or nil when the buffer cannot be converted.
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.target)
        }
        guard let converter else { return nil }
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// The phone's microphone through `AVAudioEngine`.
final class EngineMicSource: MicSource {
    private let engine = AVAudioEngine()
    private var running = false
    private var observers: [NSObjectProtocol] = []
    var onFailure: (@Sendable (String) -> Void)?
    var onInterrupted: (@Sendable (String) -> Void)?

    func start() async throws -> AsyncStream<Data> {
        guard await AVAudioApplication.requestRecordPermission() else { throw MicError.denied }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            throw MicError.unavailable(error.localizedDescription)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.unavailable("no input") }
        let converter = PCMConverter()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let pcm = converter.convert(buffer) { continuation.yield(pcm) }
        }
        continuation.onTermination = { [weak self] _ in self?.teardown() }
        do {
            try engine.start()
        } catch {
            teardown()
            throw MicError.unavailable(error.localizedDescription)
        }
        running = true
        finish = { continuation.finish() }
        observeFailures()
        return stream
    }

    /// The engine stops itself on a route or format change, and the session ends under a call or Siri. Without these observers the
    /// recording would stall with the button still on Stop.
    private func observeFailures() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.captureDied("The audio route changed, so the microphone stopped.")
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
                self?.captureInterrupted("Another app or a call took over the microphone.")
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                self?.captureDied("The audio system restarted, so the microphone stopped.")
            },
        ]
    }

    private func captureDied(_ reason: String) {
        guard running else { return }
        finish()
        teardown()
        onFailure?(reason)
    }

    /// A call or Siri took the microphone. The stream ends with what was captured, and the model sends that.
    private func captureInterrupted(_ reason: String) {
        guard running else { return }
        finish()
        teardown()
        (onInterrupted ?? onFailure)?(reason)
    }

    private var finish: () -> Void = {}

    func stop() {
        finish()
        teardown()
    }

    private func teardown() {
        guard running else { return }
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// An audio file in place of the microphone, for tests and previews. The stream ends when the file does.
final class FileMicSource: MicSource {
    private let url: URL
    private var task: Task<Void, Never>?
    var onFailure: (@Sendable (String) -> Void)?

    init(url: URL) { self.url = url }

    func start() async throws -> AsyncStream<Data> {
        let file = try AVAudioFile(forReading: url)
        let converter = PCMConverter()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        task = Task.detached {
            let chunk: AVAudioFrameCount = 4096
            while !Task.isCancelled, file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                do { try file.read(into: buffer, frameCount: chunk) } catch { break }
                if buffer.frameLength == 0 { break }
                if let pcm = converter.convert(buffer) { continuation.yield(pcm) }
            }
            continuation.finish()
        }
        return stream
    }

    func stop() { task?.cancel() }
}
