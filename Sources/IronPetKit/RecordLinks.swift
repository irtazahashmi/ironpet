import Foundation

/// The public ids in chat text (`task_9f3c1e`) and their links (`ironpet://task_9f3c1e`). The Mac and the phone link the same ids, so a
/// tap opens the same record. The prefixes are `RecordKind` in IronPetCore; a test there keeps the two lists equal.
public enum RecordLinks {
    public static let scheme = "ironpet"
    public static let prefixes = ["screen", "meeting", "chat", "msg", "auto", "run", "job", "notif", "page", "claim"]

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
}
