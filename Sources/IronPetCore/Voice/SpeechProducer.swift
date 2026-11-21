import Foundation

/// Where audio goes: the local speaker (`ClipPlayer`), or a test. It plays one clip at a time. A client that is not this
/// Mac takes the chunks from `SpeechProducer` and plays them itself.
@MainActor
package protocol ClipPlaying: AnyObject {
    /// Returns when the clip ended; throws `CancellationError` when `stop()` cut it short.
    func play(_ audio: Data) async throws
    func stop()
}

/// Turns text into audio chunks and plays nothing. The first chunk is one sentence so audio starts early, and the next chunk is
/// synthesized while the caller handles the current one.
package struct SpeechProducer {
    package init(synthesize: @escaping (String) async throws -> Data) {
        self.synthesize = synthesize
    }

    package var synthesize: (String) async throws -> Data

    /// The prose of a markdown reply, in the chunks that are synthesized one by one.
    package func chunks(of markdown: String) -> [String] { SpeechText.chunks(of: markdown) }

    /// Reads `chunks` in order. Call `next()` for each audio chunk, and `cancel()` to drop the one being prepared.
    @MainActor
    package func reader(for chunks: [String]) -> SpeechChunkReader { SpeechChunkReader(chunks: chunks, synthesize: synthesize) }
}

/// One pass over a reply's chunks, always one chunk ahead of the caller.
@MainActor
package final class SpeechChunkReader {
    private let chunks: [String]
    private let synthesize: (String) async throws -> Data
    private var index = 0
    private var prefetch: Task<Data, Error>?

    package init(chunks: [String], synthesize: @escaping (String) async throws -> Data) {
        self.chunks = chunks
        self.synthesize = synthesize
        prefetch = chunks.first.map { first in Task { try await synthesize(first) } }
    }

    /// The next audio chunk, or nil at the end. Throws what the server answered, or `CancellationError` after `cancel()`.
    package func next() async throws -> Data? {
        guard let pending = prefetch else { return nil }
        let audio = try await pending.value
        try Task.checkCancellation()
        index += 1
        let synthesize = synthesize
        prefetch = index < chunks.count ? Task { [text = chunks[index]] in try await synthesize(text) } : nil
        return audio
    }

    package func cancel() {
        prefetch?.cancel()
        prefetch = nil
    }
}
