import Foundation
import IronPetKit

/// Matching logic for the chat's Cmd-F search. Pure functions over `ChatItem`, so it is unit tested
/// without a view. Search is plain text, case and diacritic insensitive.
package enum ChatFind {
    /// One occurrence of the query. `segment` numbers the pieces of text one item renders (a markdown block,
    /// a table cell, a tool step), and `occurrence` numbers the matches inside that piece.
    package struct Match: Equatable {
        package init(item: UUID, segment: Int, occurrence: Int) {
            self.item = item
            self.segment = segment
            self.occurrence = occurrence
        }

        package var item: UUID
        package var segment: Int
        package var occurrence: Int
    }

    /// What one row needs to draw its highlights. Rows without a match get nil, so typing re-renders only
    /// the rows whose matches changed.
    package struct RowHighlight: Equatable {
        package init(query: String, current: Match? = nil) {
            self.query = query
            self.current = current
        }

        package var query: String
        package var current: Match?
    }

    /// Character ranges of every non-overlapping occurrence of `query` in `text`.
    package static func ranges(of query: String, in text: String) -> [Range<Int>] {
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

    /// The text of each piece an item shows, in reading order. These are the strings that are drawn,
    /// so markdown markers are not searchable and a match always has something to highlight.
    package static func segments(of item: ChatItem) -> [String] {
        switch item.kind {
        case .user(let text), .error(let text):
            return [text]
        case .assistant(let text):
            return ChatMarkdown.segments(of: text)
        case .tool(let summary, _):
            return [displayed(summary)]
        case .form(let record):
            return [record.message] + record.lines.flatMap { [$0.question, $0.answer] }
        case .notice(let text):
            return text.isEmpty ? [] : [text]
        case .screenshot:
            return []
        }
    }

    /// A tool summary as drawn: its inline markdown without the markers.
    package static func displayed(_ markdown: String) -> String {
        String(ChatMarkdown.inline(markdown).characters)
    }

    /// Every match across the transcript in reading order.
    package static func matches(query: String, in items: [ChatItem]) -> [Match] {
        guard !query.isEmpty else { return [] }
        var result: [Match] = []
        for item in items {
            for (segment, text) in segments(of: item).enumerated() {
                for occurrence in ranges(of: query, in: text).indices {
                    result.append(Match(item: item.id, segment: segment, occurrence: occurrence))
                }
            }
        }
        return result
    }

    /// The index after stepping `delta` from `current`, wrapping at both ends. Nil when there are no matches.
    package static func step(from current: Int?, count: Int, by delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return delta >= 0 ? 0 : count - 1 }
        return ((current + delta) % count + count) % count
    }

    /// Where the current match sits after the matches were recomputed. It keeps the same match when it still
    /// exists, so a streaming reply does not move the reader. Otherwise it falls back to the first match.
    /// When a streaming reply renumbers the current match away, `previousIndex` keeps the reader's place.
    package static func reconcile(current: Match?, previousIndex: Int? = nil, in matches: [Match]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let current, let index = matches.firstIndex(of: current) { return index }
        if current != nil, let previousIndex { return min(max(previousIndex, 0), matches.count - 1) }
        return 0
    }

    /// The label in the find bar.
    package static func label(query: String, count: Int, index: Int?) -> String {
        if query.isEmpty { return "" }
        guard count > 0, let index else { return "No results" }
        return "\(index + 1) of \(count)"
    }

    /// Per item highlight info for the rows that hold a match.
    package static func highlights(query: String, matches: [Match], current: Match?) -> [UUID: RowHighlight] {
        var result: [UUID: RowHighlight] = [:]
        for match in matches {
            result[match.item] = RowHighlight(query: query, current: match == current ? current : result[match.item]?.current)
        }
        return result
    }
}
