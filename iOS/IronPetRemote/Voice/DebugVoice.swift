#if DEBUG
import Foundation
import IronPetKit

/// UI tests launch with `--fake-voice`: a simulator has no microphone to speak into, and the mock server has no voice socket.
enum DebugVoice {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--fake-voice") }
}

/// A tone that swells and fades twice a second, so the waveform visibly moves.
final class PulseMicSource: MicSource {
    private var task: Task<Void, Never>?
    var onFailure: (@Sendable (String) -> Void)?

    func start() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        task = Task.detached {
            var step = 0.0
            while !Task.isCancelled {
                let amplitude = Int16(Double(Int16.max) * 0.5 * (0.5 + 0.5 * sin(step)))
                let samples = [Int16](repeating: amplitude, count: 800)
                continuation.yield(samples.withUnsafeBufferPointer { Data(buffer: $0) })
                step += 0.6
                try? await Task.sleep(for: .milliseconds(50))
            }
            continuation.finish()
        }
        return stream
    }

    func stop() { task?.cancel() }
}

/// A voice socket that accepts everything and never answers.
final class SilentVoiceChannel: VoiceChannel, @unchecked Sendable {
    private let stream: AsyncThrowingStream<VoiceInbound, Error>
    private let continuation: AsyncThrowingStream<VoiceInbound, Error>.Continuation
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func send(text: String) async throws {}
    func send(binary: Data) async throws {}
    func incoming() -> AsyncThrowingStream<VoiceInbound, Error> { stream }
    func close() { continuation.finish() }
}
#endif
