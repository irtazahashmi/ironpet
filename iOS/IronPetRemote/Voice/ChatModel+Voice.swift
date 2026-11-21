import Foundation

extension ChatModel {
    /// Adds dictated text to the composer after what is already there.
    func insertDictation(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") {
            draft += clean
        } else {
            draft += " " + clean
        }
    }
}
