import Foundation

/// A spelling the transcript should use, with the forms the transcriber is known to produce for it.
package struct KnownTerm: Equatable {
    package init(spelling: String, misheard: [String] = []) {
        self.spelling = spelling
        self.misheard = misheard
    }

    package var spelling: String
    package var misheard: [String]
}

/// Fixes words in a transcript that sound like a known term. It is deterministic and local: no model call.
///
/// A run of 1 to 4 words is rewritten to a term's spelling only when it is an unambiguous match:
/// 1. it equals a listed misheard form, ignoring case;
/// 2. it equals the term once spaces and case are ignored ("iron pet" for "IronPet"); or
/// 3. it is one edit away from the term (two for terms of 10 or more letters), starts with the same letter and has at least
///    6 letters. Shorter words are never matched this way, so ordinary words stay as they are.
/// A run that two terms match equally well is left alone.
package enum TranscriptCorrector {
    private static let maxWindow = 4
    private static let minFuzzyLength = 6

    private struct Token {
        var range: Range<String.Index>
        var text: String
    }

    private struct Candidate {
        var tokens: Range<Int>
        var term: String
        var cost: Int
    }

    package static func correct(_ text: String, terms: [KnownTerm]) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        var candidates: [Candidate] = []
        for start in tokens.indices {
            for size in 1...maxWindow where start + size <= tokens.count {
                let window = tokens[start..<(start + size)]
                // Words split by punctuation or a line break are not one spoken phrase.
                guard isOnePhrase(window, in: text) else { break }
                let words = window.map(\.text)
                for term in terms {
                    if let cost = match(words, term: term) {
                        candidates.append(Candidate(tokens: start..<(start + size), term: term.spelling, cost: cost))
                    }
                }
            }
        }

        // A run that two different terms match at the same cost is ambiguous.
        var ambiguous = Set<Range<Int>>()
        let byRun = Dictionary(grouping: candidates, by: \.tokens)
        for (run, list) in byRun {
            let best = list.map(\.cost).min() ?? 0
            if Set(list.filter { $0.cost == best }.map(\.term)).count > 1 { ambiguous.insert(run) }
        }
        let ordered = candidates.filter { !ambiguous.contains($0.tokens) }.sorted {
            if $0.cost != $1.cost { return $0.cost < $1.cost }
            if $0.tokens.count != $1.tokens.count { return $0.tokens.count > $1.tokens.count }
            return $0.tokens.lowerBound < $1.tokens.lowerBound
        }

        var taken = Set<Int>()
        var chosen: [Candidate] = []
        for candidate in ordered where candidate.tokens.allSatisfy({ !taken.contains($0) }) {
            taken.formUnion(candidate.tokens)
            chosen.append(candidate)
        }

        var result = text
        for candidate in chosen.sorted(by: { $0.tokens.lowerBound > $1.tokens.lowerBound }) {
            let range = tokens[candidate.tokens.lowerBound].range.lowerBound..<tokens[candidate.tokens.upperBound - 1].range.upperBound
            if result[range] != candidate.term { result.replaceSubrange(range, with: candidate.term) }
        }
        return result
    }

    /// The cost of reading `words` as `term`, or nil when they do not match. Zero is an exact match.
    private static func match(_ words: [String], term: KnownTerm) -> Int? {
        let spoken = words.joined(separator: " ").lowercased()
        if term.misheard.contains(where: { normalized($0) == spoken }) { return 0 }

        let squashed = spoken.filter { $0 != " " }
        let target = term.spelling.lowercased().filter { $0 != " " }
        if squashed == target {
            // "will" for the name "Will" is the user's word as often as the name, so a case-only change on one word needs a
            // term that is not an ordinary capitalised word, such as "IronPet" or "iOS".
            if words.count == 1, !hasInnerCapital(term.spelling) { return nil }
            return 1
        }
        guard squashed.count >= minFuzzyLength, squashed.first == target.first else { return nil }
        let allowed = target.count >= 10 ? 2 : 1
        guard abs(squashed.count - target.count) <= allowed else { return nil }
        let distance = editDistance(Array(squashed), Array(target))
        return distance <= allowed ? 1 + distance : nil
    }

    private static func normalized(_ form: String) -> String {
        tokenize(form).map { $0.text.lowercased() }.joined(separator: " ")
    }

    private static func hasInnerCapital(_ spelling: String) -> Bool {
        spelling.dropFirst().contains { $0.isUppercase || $0.isNumber }
    }

    /// Words are runs of letters and digits, with apostrophes and hyphens inside.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        func isWordCharacter(_ at: String.Index) -> Bool {
            let character = text[at]
            if character.isLetter || character.isNumber { return true }
            guard character == "'" || character == "’" || character == "-" else { return false }
            let next = text.index(after: at)
            return start != nil && next < text.endIndex && (text[next].isLetter || text[next].isNumber)
        }
        while index < text.endIndex {
            if isWordCharacter(index) {
                if start == nil { start = index }
            } else if let begun = start {
                tokens.append(Token(range: begun..<index, text: String(text[begun..<index])))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begun = start { tokens.append(Token(range: begun..<text.endIndex, text: String(text[begun...]))) }
        return tokens
    }

    /// True when only spaces separate the words.
    private static func isOnePhrase(_ window: ArraySlice<Token>, in text: String) -> Bool {
        guard let first = window.first else { return true }
        var previous = first
        for token in window.dropFirst() {
            let gap = text[previous.range.upperBound..<token.range.lowerBound]
            guard !gap.isEmpty, gap.allSatisfy({ $0 == " " }) else { return false }
            previous = token
        }
        return true
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
