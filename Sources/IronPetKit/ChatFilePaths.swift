import Foundation

/// Finds file paths in chat text. The Mac links the ones that exist and opens them in their app. The phone links every one and asks
/// the Mac for a preview when it is tapped, so detection is shared and pure: it never touches the disk.
public enum ChatFilePaths {
    public struct Match: Equatable, Sendable {
        /// Range in the scanned string, covering the path and its `:line` suffix.
        public var range: Range<String.Index>
        /// Absolute path with `\ ` unescaped and the `:line` suffix removed. `~/` is expanded to `home`, or stays `~/` when `home` is nil.
        public var path: String

        public init(range: Range<String.Index>, path: String) { self.range = range; self.path = path }
    }

    private static let stopCharacters: Set<Character> = ["`", "\"", "'", "<", ">", "|", "*"]
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
    private static let boundaryBefore: Set<Character> = ["(", "[", "{", "\"", "'", "`", "=", ",", ";", ">", "*"]

    /// Finds absolute paths, `~/` paths and `file://` URLs. `home` is what `~/` stands for on this device.
    public static func detect(in text: String, home: String?) -> [Match] {
        var matches: [Match] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard isStart(text, at: i) else { i = text.index(after: i); continue }
            let end = candidateEnd(text, from: i)
            if let match = match(text, from: i, to: end, home: home) {
                matches.append(match)
                i = match.range.upperBound
            } else {
                i = text.index(after: i)
            }
        }
        return matches
    }

    private static func isStart(_ text: String, at i: String.Index) -> Bool {
        let rest = text[i...]
        guard rest.hasPrefix("/") || rest.hasPrefix("~/") || rest.hasPrefix("file://") else { return false }
        if rest.hasPrefix("//") { return false }
        guard i > text.startIndex else { return true }
        let before = text[text.index(before: i)]
        return before.isWhitespace || boundaryBefore.contains(before)
    }

    /// Runs to the first unescaped space or stop character.
    private static func candidateEnd(_ text: String, from start: String.Index) -> String.Index {
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if c == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == " " {
                i = text.index(i, offsetBy: 2)
                continue
            }
            if c.isWhitespace || stopCharacters.contains(c) { break }
            i = text.index(after: i)
        }
        return i
    }

    private static func match(_ text: String, from start: String.Index, to end: String.Index, home: String?) -> Match? {
        var raw = String(text[start..<end])
        var spanned: String?
        while true {
            let before = raw
            raw = trimTrailing(raw)
            if let suffix = raw.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
                if spanned == nil { spanned = raw }
                raw.removeSubrange(suffix)
            }
            if raw == before { break }
        }
        // Characters that were cut from a `\ ` pair must not leave a dangling backslash.
        if raw.hasSuffix("\\") { raw.removeLast() }
        // The range also covers a `:line` suffix, which is not part of the path.
        let span = spanned.map { $0.hasPrefix(raw) ? $0 : raw } ?? raw
        let stop = text.index(start, offsetBy: span.count)

        guard let path = resolvedPath(raw, home: home), path.split(separator: "/").count >= 2 else { return nil }
        if raw.hasPrefix("~/"), raw.count <= 2 { return nil }
        return Match(range: start..<stop, path: path)
    }

    /// Drops closing punctuation, keeping a `)` that closes a `(` inside the path.
    private static func trimTrailing(_ value: String) -> String {
        var value = value
        while let last = value.last, trailingPunctuation.contains(last) {
            if last == ")", value.filter({ $0 == "(" }).count >= value.filter({ $0 == ")" }).count { break }
            value.removeLast()
        }
        return value
    }

    private static func resolvedPath(_ raw: String, home: String?) -> String? {
        var path = raw
        if path.hasPrefix("file://") {
            guard let url = URL(string: path) ?? URL(string: path.replacingOccurrences(of: " ", with: "%20")), url.isFileURL
            else { return nil }
            path = url.path
        } else {
            path = path.replacingOccurrences(of: "\\ ", with: " ")
            if path.hasPrefix("~/"), let home { path = home + path.dropFirst() }
        }
        guard path.hasPrefix("/") || path.hasPrefix("~/"), path.count > 1 else { return nil }
        return path
    }

    // MARK: Links on the phone

    /// The scheme of a link that opens a Mac file preview on the phone.
    public static let scheme = "ironpet-file"

    /// The link a detected path gets on the phone. The path travels in a query item, so spaces and `#` survive.
    public static func link(forPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "preview"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// The path a preview link names, or nil for any other URL.
    public static func path(from url: URL) -> String? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "path" }?.value
    }
}

/// What the Mac sent for a file preview.
public struct RemoteFilePreview: Equatable, Sendable {
    public var path: String
    public var contentType: String
    public var data: Data
    /// True when a text file was longer than the Mac sends, so `data` is only its start.
    public var truncated: Bool

    public init(path: String, contentType: String, data: Data, truncated: Bool) {
        self.path = path; self.contentType = contentType; self.data = data; self.truncated = truncated
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var isImage: Bool { contentType.hasPrefix("image/") }
    /// The text of a text file. A body with a NUL byte is binary, and so is anything that is not UTF-8.
    public var text: String? { isImage || data.contains(0) ? nil : String(data: data, encoding: .utf8) }
}
