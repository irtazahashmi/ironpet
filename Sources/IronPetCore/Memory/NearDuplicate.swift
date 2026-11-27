import Foundation

/// A cheap, offline test for two notes that say the same fact in different words. It compares the content words of both notes, so a
/// restatement ("bloated with features he does not need" and "bloated with features that are unnecessary") counts and two different
/// facts about one subject do not.
///
/// A pair is a near-duplicate when both hold:
/// - the Jaccard similarity of the content words is at least `minSimilarity`, and
/// - the notes share at least `minShared` content words.
///
/// The numbers come from the pairs in `NearDuplicateTests`. Three rewordings of one Orca complaint score 0.32, 0.37 and 0.33 against
/// the first wording, and a reworded Jira rule scores 0.86. Distinct facts about one subject score 0.10 to 0.29, the highest being two
/// Orca worktree facts at 0.29. A threshold of 0.30 sits between the lowest restatement (0.32) and the highest distinct pair (0.29), so
/// the margin is thin on both sides and the test pairs pin it. The shared-word floor of 5 keeps short notes that differ in one word
/// ("Uses npm" and "Uses pnpm") apart, which Jaccard alone would score high.
///
/// Limits: two facts that differ in one verb and share the rest of a long sentence ("closed once the PR merged" and "assigned when
/// the agent opens the PR" score 0.33) look like a restatement to any word-overlap test and are merged. A wrong merge keeps the older
/// wording and drops the newer fact, so the threshold leans toward keeping both notes, and the model-written `replaces` stays the
/// main way to retire a note.
package enum NearDuplicate {
    package static let minSimilarity = 0.30
    package static let minShared = 5

    /// Words that carry no fact. Kept short on purpose: a longer list starts removing words that tell two facts apart.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "for", "with", "at", "by", "from", "as", "is", "are", "be", "was",
        "were", "it", "its", "that", "this", "these", "those", "he", "she", "they", "his", "her", "their", "not", "no", "do", "does",
        "did", "has", "have", "had", "so", "can", "will", "would", "should", "may", "might", "into", "than", "then", "too", "very",
        "only", "more", "most", "some", "any", "other", "which", "who", "what", "when", "where", "while", "about", "across", "over",
        "under", "up", "out", "off", "per", "via", "also", "just", "s",
    ]

    /// The content words of a note: lowercase letters and digits, stop words dropped, plurals and common endings trimmed.
    package static func words(_ text: String) -> Set<String> {
        var result = Set<String>()
        var current = ""
        func flush() {
            if current.count > 1, !stopWords.contains(current) { result.insert(stem(current)) }
            current = ""
        }
        for character in text.lowercased() {
            if character.isLetter || character.isNumber { current.append(character) } else { flush() }
        }
        flush()
        return result
    }

    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "ly", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// Jaccard similarity of two notes' content words, or nil when they share fewer than `minShared` of them.
    package static func similarity(_ a: String, _ b: String) -> Double? {
        similarity(words(a), words(b))
    }

    package static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double? {
        let shared = a.intersection(b).count
        guard shared >= minShared else { return nil }
        return Double(shared) / Double(a.union(b).count)
    }

    package static func areNear(_ a: String, _ b: String) -> Bool {
        (similarity(a, b) ?? 0) >= minSimilarity
    }

    /// The claim in `candidates` most like `text`, when one is a near-duplicate. Ties go to the earlier candidate.
    package static func best<T>(for text: String, in candidates: [T], text of: (T) -> String) -> T? {
        let wanted = words(text)
        var best: (item: T, score: Double)?
        for candidate in candidates {
            guard let score = similarity(wanted, words(of(candidate))), score >= minSimilarity, score > (best?.score ?? 0) else { continue }
            best = (candidate, score)
        }
        return best?.item
    }

    /// Groups of notes that are near-duplicates of each other, as index lists of two or more. A note joins a group when it is near any
    /// member, so a chain of rewordings forms one group.
    package static func groups(_ texts: [String]) -> [[Int]] {
        let sets = texts.map(words)
        var parent = Array(texts.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        for i in texts.indices {
            for j in texts.indices where j > i {
                if let score = similarity(sets[i], sets[j]), score >= minSimilarity { parent[root(j)] = root(i) }
            }
        }
        return Dictionary(grouping: texts.indices, by: root).values.filter { $0.count >= 2 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}
