import Foundation

/// The public ids in chat text (`task_9f3c1e`) and their links (`ironpet://task_9f3c1e`). The Mac and the phone link the same ids, so a
/// tap opens the same record. The prefixes are `RecordKind` in IronPetCore; a test there keeps the two lists equal.
public enum RecordLinks {
    public static let scheme = "ironpet"
    public static let prefixes = ["screen", "meeting", "chat", "msg", "task", "auto", "run", "job", "notif", "page", "claim", "filter"]

    /// An id stands alone: not inside a word, a path, a file name or a URL, and not followed by a dot and more text.
    private static let pattern: NSRegularExpression = {
        let kinds = prefixes.joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_/.~\\-])(?:\(kinds))_[0-9a-f]{6,}(?![A-Za-z0-9_/\\-])(?!\\.[A-Za-z0-9])")
    }()

    /// Each id in `text` with its range. Text is not checked against a store: a dead id is still an id.
    public static func detect(in text: String) -> [(range: Range<String.Index>, id: String)] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return (range, String(text[range]))
        }
    }

    /// The link for a record id.
    public static func url(for id: String) -> URL? {
        URL(string: "\(scheme)://\(id)")
    }

    /// The record id a `ironpet://<id>` link names. Nil for any other link, such as the pairing link `ironpet://pair?…`.
    public static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, let host = url.host, url.query == nil else { return nil }
        let whole = NSRange(host.startIndex..., in: host)
        guard pattern.firstMatch(in: host, range: whole)?.range == whole else { return nil }
        return host
    }

    /// Links each id in `text` that is not already a link and not code. The text itself does not change.
    public static func link(_ text: AttributedString) -> AttributedString {
        let plain = String(text.characters)
        guard plain.contains("_") else { return text }
        var result = text
        for match in detect(in: plain) {
            let offset = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let lower = result.characters.index(result.characters.startIndex, offsetBy: offset)
            let upper = result.characters.index(lower, offsetBy: length)
            let runs = result[lower..<upper].runs
            guard runs.allSatisfy({ $0.link == nil && !isCode($0) }), let url = url(for: match.id) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }

    /// Whether a run is a code span from Markdown. The attribute is named explicitly because Linux's Foundation cannot infer it through dynamic member lookup.
    private static func isCode(_ run: AttributedString.Runs.Run) -> Bool {
        let intent: InlinePresentationIntent? = run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
        return intent?.contains(.code) == true
    }
}
