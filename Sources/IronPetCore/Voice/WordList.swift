import Foundation

/// A term the user wants dictation to spell correctly, with the ways it tends to come out wrong.
package struct WordTerm: Codable, Equatable, Identifiable {
    package init(term: String, misheard: [String] = []) {
        self.term = term
        self.misheard = misheard
    }

    package var term: String
    /// Spellings the transcriber produces for this term, such as "length fuse" for "Langfuse".
    package var misheard: [String]

    package var id: String { term.lowercased() }
}

/// The user's personal word list. It is one JSON file under `~/.ironpet`, so it stays on this Mac and is never sent to the hub.
@MainActor
package final class WordListStore: ObservableObject {
    package nonisolated static var defaultURL: URL { Paths.root.appendingPathComponent("word-list.json") }

    @Published package private(set) var terms: [WordTerm] = []
    private let url: URL

    package init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        reload()
    }

    /// Reads the file again. A missing or unreadable file gives an empty list.
    package func reload() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WordTerm].self, from: data) else {
            terms = []
            return
        }
        terms = decoded
    }

    /// Adds a term, or merges the misheard forms into the entry that already has the same spelling (ignoring case).
    package func add(_ term: String, misheard: [String] = []) {
        let spelled = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelled.isEmpty else { return }
        let forms = Self.cleaned(misheard, excluding: spelled)
        if let index = terms.firstIndex(where: { $0.id == spelled.lowercased() }) {
            terms[index].term = spelled
            for form in forms where !terms[index].misheard.contains(where: { $0.caseInsensitiveCompare(form) == .orderedSame }) {
                terms[index].misheard.append(form)
            }
        } else {
            terms.append(WordTerm(term: spelled, misheard: forms))
        }
        save()
    }

    /// Replaces the entry `id` names. Renaming onto another entry's spelling is refused.
    @discardableResult
    package func update(id: String, term: String, misheard: [String]) -> Bool {
        let spelled = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelled.isEmpty, let index = terms.firstIndex(where: { $0.id == id }) else { return false }
        if spelled.lowercased() != id, terms.contains(where: { $0.id == spelled.lowercased() }) { return false }
        terms[index] = WordTerm(term: spelled, misheard: Self.cleaned(misheard, excluding: spelled))
        save()
        return true
    }

    package func remove(id: String) {
        terms.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(terms).write(to: url, options: .atomic)
        } catch {
            VoiceTiming.log.notice("Could not save the word list: \(error.localizedDescription)")
        }
    }

    private static func cleaned(_ forms: [String], excluding term: String) -> [String] {
        var seen: Set<String> = [term.lowercased()]
        var result: [String] = []
        for form in forms {
            let trimmed = form.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted { result.append(trimmed) }
        }
        return result
    }
}
