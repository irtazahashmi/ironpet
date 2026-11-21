import Foundation

/// One speaker found inside a single chunk. The ids are local to the chunk: "1" in one chunk and "1" in the next
/// are unrelated until `MeetingSpeakerTable` links them by voice.
struct ChunkSpeaker: Equatable {
    var localId: String
    /// One embedding for the whole speaker, the duration-weighted mean over their segments.
    var embedding: [Float]
    /// Seconds from the start of the chunk.
    var turns: [ClosedRange<TimeInterval>]

    var seconds: TimeInterval { turns.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    var longestTurn: ClosedRange<TimeInterval>? { turns.max { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound } }
}

struct ChunkDiarization: Equatable {
    var speakers: [ChunkSpeaker]
}

protocol SpeakerDiarizing: Sendable {
    /// Splits a chunk's WAV into speakers. Throws when the models are missing or the audio cannot be read.
    func diarize(wav: URL) async throws -> ChunkDiarization
}

/// Finds no speakers. A regenerator or controller that is given no diarizer uses it, and the transcript stays by track.
struct UnsupportedDiarizer: SpeakerDiarizing {
    var platform = PlatformName.current

    init() {}

    func diarize(wav: URL) async throws -> ChunkDiarization {
        throw CapabilityError.unsupported(capability: "SpeakerDiarizing", platform: platform)
    }
}
