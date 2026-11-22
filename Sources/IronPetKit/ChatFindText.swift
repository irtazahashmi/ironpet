import Foundation

/// The text rules of chat search that the Mac and the phone share: what counts as a match, how the current match steps, how it
/// survives new content, and the label in the find bar. The Mac's `ChatFind` and the phone's `RemoteChatFind` build on it, each over
/// its own item type.
public enum ChatFindText {
    /// Character ranges of every non-overlapping occurrence of `query` in `text`. Search ignores case and diacritics.
    public static func ranges(of query: String, in text: String) -> [Range<Int>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var result: [Range<Int>] = []
        var from = text.startIndex
        var offset = 0
        while from < text.endIndex, let found = text.range(of: query, options: options, range: from..<text.endIndex) {
            guard !found.isEmpty else { break }
            let lower = offset + text.distance(from: from, to: found.lowerBound)
            let upper = lower + text.distance(from: found.lowerBound, to: found.upperBound)
            result.append(lower..<upper)
            offset = upper
            from = found.upperBound
        }
        return result
    }

    /// The index after stepping `delta` from `current`, wrapping at both ends. Nil when there are no matches.
    public static func step(from current: Int?, count: Int, by delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return delta >= 0 ? 0 : count - 1 }
        return ((current + delta) % count + count) % count
    }

    /// Where the current match sits after the matches were recomputed. It keeps the same match when it still exists, so a streaming
    /// reply does not move the reader. When a streaming reply renumbers the current match away, `previousIndex` keeps the reader's
    /// place. Otherwise it falls back to the first match.
    public static func reconcile<Match: Equatable>(current: Match?, previousIndex: Int? = nil, in matches: [Match]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let current, let index = matches.firstIndex(of: current) { return index }
        if current != nil, let previousIndex { return min(max(previousIndex, 0), matches.count - 1) }
        return 0
    }

    /// The label in the find bar: "3 of 12", "No results", or nothing before the reader types.
    public static func label(query: String, count: Int, index: Int?) -> String {
        if query.isEmpty { return "" }
        guard count > 0, let index else { return "No results" }
        return "\(index + 1) of \(count)"
    }
}

/// Search over the phone's transcript. Only what a person or the agent wrote is searched, in the text the rows draw, so a markdown
/// marker is not a match and every match has something to highlight. Tool steps, notices, forms and attachments are not searched.
public enum RemoteChatFind {
    /// One occurrence of the query. `segment` numbers the pieces of text one message draws (a markdown block, a table cell) and
    /// `occurrence` numbers the matches inside that piece.
    public struct Match: Equatable, Sendable {
        public var itemID: String
        public var segment: Int
        public var occurrence: Int

        public init(itemID: String, segment: Int, occurrence: Int) { self.itemID = itemID; self.segment = segment; self.occurrence = occurrence }
    }

    /// What one row needs to draw its highlights. Rows without a match get none, so typing redraws only the rows that changed.
    public struct RowHighlight: Equatable, Sendable {
        public var query: String
        public var current: Match?

        public init(query: String, current: Match? = nil) { self.query = query; self.current = current }
    }

    /// The text of each piece a message draws, in reading order.
    public static func segments(of item: RemoteChatItem) -> [String] {
        switch item.row {
        case .user(let text): return [text]
        case .assistant(let text): return ChatMarkdown.segments(of: text)
        default: return []
        }
    }

    /// Every match across the transcript in reading order.
    public static func matches(query: String, in items: [RemoteChatItem]) -> [Match] {
        guard !query.isEmpty else { return [] }
        var result: [Match] = []
        for item in items {
            for (segment, text) in segments(of: item).enumerated() {
                for occurrence in ChatFindText.ranges(of: query, in: text).indices {
                    result.append(Match(itemID: item.id, segment: segment, occurrence: occurrence))
                }
            }
        }
        return result
    }

    /// The highlight of each message that holds a match, by message id.
    public static func highlights(query: String, matches: [Match], current: Match?) -> [String: RowHighlight] {
        var result: [String: RowHighlight] = [:]
        for match in matches {
            result[match.itemID] = RowHighlight(query: query, current: match == current ? current : result[match.itemID]?.current)
        }
        return result
    }
}
