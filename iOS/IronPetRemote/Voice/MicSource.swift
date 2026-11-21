import AVFoundation
import Foundation

/// A source of microphone audio as 16 kHz mono 16-bit little-endian PCM, in chunks of any size.
protocol MicSource: AnyObject {
    /// Starts capturing. The stream ends after `stop()`, or when a file source runs out of audio.
    func start() async throws -> AsyncStream<Data>
    func stop()
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
        return stream
    }

    private var finish: () -> Void = {}

    func stop() {
        finish()
        teardown()
    }

    private func teardown() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// An audio file in place of the microphone, for tests and previews. The stream ends when the file does.
final class FileMicSource: MicSource {
    private let url: URL
    private var task: Task<Void, Never>?

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
