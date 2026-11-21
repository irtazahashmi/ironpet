import Foundation

/// One speaker found inside a single chunk. The ids are local to the chunk: "1" in one chunk and "1" in the next
/// are unrelated until `MeetingSpeakerTable` links them by voice.
package struct ChunkSpeaker: Equatable {
    package init(localId: String, embedding: [Float], turns: [ClosedRange<TimeInterval>]) {
        self.localId = localId
        self.embedding = embedding
        self.turns = turns
    }

    package var localId: String
    /// One embedding for the whole speaker, the duration-weighted mean over their segments.
    package var embedding: [Float]
    /// Seconds from the start of the chunk.
    package var turns: [ClosedRange<TimeInterval>]

    package var seconds: TimeInterval { turns.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    package var longestTurn: ClosedRange<TimeInterval>? { turns.max { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound } }
}

package struct ChunkDiarization: Equatable {
    package init(speakers: [ChunkSpeaker]) {
        self.speakers = speakers
    }

    package var speakers: [ChunkSpeaker]
}

package protocol SpeakerDiarizing: Sendable {
    /// Splits a chunk's WAV into speakers. Throws when the models are missing or the audio cannot be read.
    func diarize(wav: URL) async throws -> ChunkDiarization
}

/// Finds no speakers. A regenerator or controller that is given no diarizer uses it, and the transcript stays by track.
package struct UnsupportedDiarizer: SpeakerDiarizing {
    package var platform = PlatformName.current

    package init() {}

    package func diarize(wav: URL) async throws -> ChunkDiarization {
        throw CapabilityError.unsupported(capability: "SpeakerDiarizing", platform: platform)
    }
}
