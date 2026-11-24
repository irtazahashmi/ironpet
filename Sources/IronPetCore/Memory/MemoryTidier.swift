import Foundation

/// Shrinks a memory file that went over its size limit: the agent merges duplicates and drops notes newer ones replace, and ironpet
/// checks the answer before writing it. A result is thrown away, and the file stays as it is, when it is not smaller, changes the
/// headings, adds a line that is not a note and was not there, has a note line whose date and source no original note had, or
/// keeps fewer than a third of the notes. The old file goes to `.history` like any change. A file whose last answer was thrown
/// away is not sent again until it changes, so a file that cannot shrink does not cost a pass every time.
@MainActor
package enum MemoryTidier {
    /// The text is `prompts/memory-tidier.md`.
    package static func prompt(file: String, limit: Int) -> String {
        Prompts.render(id: "memory-tidier", ["limit": String(limit), "file": file])
    }

    package enum Rejection: Error, Equatable {
        case notJSON, notSmaller, headingsChanged, unknownLine(String), unknownTrailer(String), tooFew
    }

    /// The new file text, when it passes every check against `original`.
    package static func validate(original: String, answer: String) -> Result<String, Rejection> {
        guard let object = MemoryReflector.jsonObject(in: answer), let proposed = object["file"] as? String else { return .failure(.notJSON) }
        let before = MemoryDocument(original), after = MemoryDocument(proposed)
        guard after.text.utf8.count < before.text.utf8.count else { return .failure(.notSmaller) }
        let headings = { (d: MemoryDocument) in Set(d.lines.filter { $0.hasPrefix("#") }) }
        guard headings(after) == headings(before) else { return .failure(.headingsChanged) }
        let trailers = Set(before.notes.compactMap { note in note.date.map { "\($0) \(note.source)" } })
        let handWritten = Set(before.notes.filter { $0.date == nil }.map(\.text))
        let otherLines = Set(before.lines)
        for line in after.lines where !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let note = MemoryNote.parse(line) else {
                if otherLines.contains(line) { continue }
                return .failure(.unknownLine(line))
            }
            if let date = note.date {
                guard trailers.contains("\(date) \(note.source)") else { return .failure(.unknownTrailer(line)) }
                guard case .success = MemoryNote.clean(note.text) else { return .failure(.unknownLine(line)) }
            } else if !handWritten.contains(note.text) {
                return .failure(.unknownLine(line))
            }
        }
        guard after.notes.count * 3 >= before.notes.count, before.notes.isEmpty || !after.notes.isEmpty else { return .failure(.tooFew) }
        return .success(after.text)
    }

    /// The text of each file, by path, whose last tidy answer was thrown away.
    private static var rejected: [String: String] = [:]

    /// Runs one tidy pass on `url`. Returns true when the file was rewritten.
    @discardableResult
    package static func tidy(_ url: URL, limit: Int, store: FileMemoryStore, reader: MemoryReflector.Reader, runner: MemoryReflector.Runner) async -> Bool {
        let original = store.text(url)
        guard original.utf8.count > limit, rejected[url.path] != original else { return false }
        switch await runner(prompt(file: original, limit: limit), reader) {
        case .failure(let failure):
            NSLog("ironpet: memory tidy of \(store.relativePath(url)) failed: \(failure.message)")
            return false
        case .success(let answer):
            // The file may have changed while the agent ran; only replace the version it read.
            guard store.text(url) == original else { return false }
            switch validate(original: original, answer: answer) {
            case .failure(let rejection):
                NSLog("ironpet: memory tidy of \(store.relativePath(url)) was not used: \(rejection)")
                rejected[url.path] = original
                return false
            case .success(let text):
                let before = MemoryDocument(original).notes.count, after = MemoryDocument(text).notes.count
                return (try? store.rewrite(url, with: text, action: .tidied, source: "tidy",
                                           summary: "Tidied \(store.title(url)): \(before) notes to \(after)").get()) != nil
            }
        }
    }
}
