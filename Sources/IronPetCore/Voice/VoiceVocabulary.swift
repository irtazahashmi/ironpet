import Foundation

/// The terms voice input should spell correctly: the user's word list plus the names IronPet's memory already knows.
/// Every voice path asks this for a prompt to send with the audio and for the correction of the transcript it gets back.
@MainActor
package final class VoiceVocabulary {
    /// The app's vocabulary. Tests build their own.
    package static var shared = VoiceVocabulary()

    /// A prompt carries at most this many terms and characters, so a long list does not crowd out the audio's context.
    package static let maxPromptTerms = 200
    package static let maxPromptCharacters = 800
    /// A memory name shorter than this is more likely a word than a name.
    private static let minMemoryNameLength = 3

    package let wordList: WordListStore
    /// The names of memory entities. The default reads the app's memory store.
    package var entityNames: () -> [String]
    /// How long correcting may take. Past it, the raw transcript is delivered.
    package var budget: TimeInterval = 0.15
    /// Rewrites a transcript. Tests replace it to make it fail or stall.
    package var corrector: @Sendable (String, [KnownTerm]) async throws -> String = { TranscriptCorrector.correct($0, terms: $1) }

    package init(wordList: WordListStore? = nil,
                 entityNames: (() -> [String])? = nil) {
        self.wordList = wordList ?? WordListStore()
        self.entityNames = entityNames ?? { EntityMemoryStore.shared.entities().map(\.name) }
    }

    /// Word list terms first, then memory names the list does not already have. Read when a transcript arrives, so a change
    /// in Settings or in memory counts from the next recording.
    package func knownTerms() -> [KnownTerm] {
        var terms = wordList.terms.map { KnownTerm(spelling: $0.term, misheard: $0.misheard) }
        var seen = Set(terms.map { $0.spelling.lowercased() })
        for name in entityNames() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= Self.minMemoryNameLength, seen.insert(trimmed.lowercased()).inserted {
                terms.append(KnownTerm(spelling: trimmed))
            }
        }
        return terms
    }

    /// The `prompt` field for the transcription request, or nil when no term is known.
    package func prompt() -> String? {
        Self.prompt(for: knownTerms())
    }

    package static func prompt(for terms: [KnownTerm]) -> String? {
        var result = ""
        for term in terms.prefix(maxPromptTerms) {
            let next = result.isEmpty ? term.spelling : result + ", " + term.spelling
            if next.count > maxPromptCharacters { break }
            result = next
        }
        return result.isEmpty ? nil : result
    }

    /// The transcript with known terms spelled correctly. Any failure, or running past `budget`, gives back `text` unchanged.
    package func correct(_ text: String) async -> String {
        let terms = knownTerms()
        guard !terms.isEmpty, !text.isEmpty else { return text }
        let corrector = corrector
        let corrected = await Self.within(budget) { try await corrector(text, terms) }
        return corrected ?? text
    }

    /// The user corrected a word in a transcript and chose to add it to the word list.
    package func learn(heard: String, spelled: String) {
        wordList.add(spelled, misheard: [heard])
    }

    /// Runs `work` and returns its result, or nil when it throws or takes longer than `seconds`. The caller is released at the
    /// deadline even when `work` ignores cancellation.
    nonisolated static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once(continuation)
            let job = Task {
                let value = try? await work()
                once.resume(value)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(nil)
                job.cancel()
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func resume(_ value: T?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
