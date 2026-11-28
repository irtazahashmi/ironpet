import Foundation

/// Rewrites a speaker's name inside saved meetings after a stored voice was renamed.
///
/// A meeting folder keeps no speaker map. The only record of who spoke is the label in each transcript line
/// (`[14:02:10] Jonas Ruskanen: text`), so a meeting counts as having the voice when one of its transcript labels is
/// the old name. Other meetings are left alone, even when they mention the name in free text.
package enum SpeakerRename {
    /// The files of a meeting that carry speaker names. The `.prev.md` copies come from "Regenerate".
    private static let files = ["transcript.md", "summary.md", "transcript.prev.md", "summary.prev.md"]

    package struct Outcome: Equatable {
        package var meetings = 0
        package var failed = 0
    }

    /// True when a line of the transcript is labelled `name`.
    package static func hasSpeaker(_ name: String, in transcript: String) -> Bool {
        transcript.components(separatedBy: "\n").contains { label(of: $0)?.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The transcript with `old` replaced by `new` in the labels only. Spoken text stays as it is.
    package static func renameLabels(in transcript: String, from old: String, to new: String) -> String {
        transcript.components(separatedBy: "\n").map { line in
            guard let label = label(of: line), label.caseInsensitiveCompare(old) == .orderedSame,
                  let colon = line.range(of: "\(label):") else { return line }
            return line.replacingCharacters(in: colon, with: "\(new):")
        }.joined(separator: "\n")
    }

    /// The summary with every whole-word `old` replaced by `new`. A word that only contains the name stays.
    package static func renameNames(in text: String, from old: String, to new: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: new))
    }

    /// Rewrites every meeting under `root` that has a line from `old`, except the folders in `skipping`. Each file is
    /// replaced in one atomic write, so a failure leaves a file either as it was or fully renamed.
    package static func apply(root: URL, from old: String, to new: String, skipping: Set<URL> = []) -> Outcome {
        var outcome = Outcome()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let skipped = Set(skipping.map { $0.standardizedFileURL.path })
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !skipped.contains(folder.standardizedFileURL.path),
                  let transcript = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8),
                  hasSpeaker(old, in: transcript) else { continue }
            if renameInFolder(folder, from: old, to: new) { outcome.meetings += 1 } else { outcome.failed += 1 }
        }
        return outcome
    }

    /// Rewrites the speaker's name in one meeting folder. False when a file could not be written.
    package static func renameInFolder(_ folder: URL, from old: String, to new: String) -> Bool {
        var failed = false
        for name in files {
            let url = folder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rewritten = name.hasPrefix("transcript") ? renameLabels(in: text, from: old, to: new) : renameNames(in: text, from: old, to: new)
            guard rewritten != text else { continue }
            do { try rewritten.write(to: url, atomically: true, encoding: .utf8) } catch { failed = true }
        }
        return !failed
    }

    /// `Name` in `[14:02:10] Name: text`, or nil for a line that is not a spoken line.
    private static func label(of line: String) -> String? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let rest = line[line.index(after: close)...].drop { $0 == " " }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[..<colon]
        return name.isEmpty ? nil : String(name)
    }
}
