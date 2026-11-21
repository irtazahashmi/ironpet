import AVFoundation
import IronPetCore

/// The Mac adapter for `AudioTranscoder`. AVFoundation decodes WAV, MP3, M4A and MP4 audio. On macOS it does not read OGG/Opus,
/// which is what Telegram voice messages are, so those return nil and go to the server as they are.
struct MacAudioTranscoder: AudioTranscoder {
    init() {}

    func wav(from file: URL, maxSeconds: Double) throws -> Data? {
        guard let input = try? AVAudioFile(forReading: file), input.length > 0 else { return nil }
        let format = input.processingFormat
        guard Double(input.length) / format.sampleRate <= maxSeconds,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(WAV.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)),
              (try? input.read(into: buffer)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(input.length) * target.sampleRate / format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else { return nil }
        return WAV.encode(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }
}
