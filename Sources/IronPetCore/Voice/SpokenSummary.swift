import Foundation

/// The short summary a reply starts with when it is read aloud. The agent writes it as the reply's first line, so
/// speaking it needs no second model call, and the rest of the reply is the full answer that stays in the chat.
package enum SpokenSummary {
    /// Appended to the prompt of a turn whose reply is read aloud. The prompt stored in the chat does not hold it.
    package static let note = "[Your reply is read aloud, so start it with a summary of the answer in one or two plain spoken sentences, with no markdown, on a line of its own. Then a blank line and the full answer, which only appears in the chat.]"

    /// The longest summary read as written. A longer first line means the agent ignored the instruction, and only its
    /// first two sentences are read.
    package static let maxCharacters = 300

    package static func prompt(_ prompt: String, on: Bool) -> String {
        on ? prompt + "\n\n" + note : prompt
    }

    /// The summary in a reply that may still be streaming: its first line, once the line is complete. With `final`, the
    /// reply is finished, so a reply of one line is its own summary. Nil when there is nothing to read yet.
    package static func summary(in reply: String, final: Bool) -> String? {
        let text = reply.drop { $0.isWhitespace }
        let line: Substring
        if let end = text.firstIndex(where: \.isNewline) {
            line = text[..<end]
        } else if final {
            line = text
        } else {
            return nil
        }
        let first = line.trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty else { return nil }
        guard first.count > maxCharacters else { return first }
        let sentences = SpeechText.completeSentences(first, final: true).sentences
        let short = sentences.prefix(2).joined(separator: " ")
        return short.isEmpty ? String(first.prefix(maxCharacters)) : short
    }
}
