import Foundation

// What the phone's chat needs to draw a transcript the way the Mac does. These mirror the Mac's `Markdown.parse`, `MessageCollapse`,
// `TranscriptGroup`, `ToolSteps` and `TranscriptFollow`, which live in the Mac target and cannot be imported here. Keep the numbers and
// rules the same as the Mac's; a change there needs the same change here.

// MARK: Markdown blocks

/// Block-level markdown for agent replies: headings, lists, quotes, code blocks, tables and rules. Inline markdown inside a block is
/// left for the view, which hands it to `AttributedString(markdown:)`.
public enum ChatMarkdown {
    public struct ListItem: Equatable, Sendable {
        public var indent: Int
        public var marker: String
        public var text: String

        public init(indent: Int, marker: String, text: String) { self.indent = indent; self.marker = marker; self.text = text }

        /// `- [ ] todo` and `- [x] done` draw as checkboxes.
        public var task: (done: Bool, text: String)? {
            for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(prefix) {
                return (done, String(text.dropFirst(prefix.count)))
            }
            return nil
        }

        public static func == (a: Self, b: Self) -> Bool { a.indent == b.indent && a.marker == b.marker && a.text == b.text }
    }

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(ordered: Bool, items: [ListItem])
        case quote(String)
        /// `closed` is false while a reply is still streaming the block.
        case code(language: String?, text: String, closed: Bool)
        case table(header: [String], rows: [[String]])
        case rule
    }

    public static func parse(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let fence = fence(trimmed) {
                flush()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        closed = true
                        i += 1
                        break
                    }
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n"), closed: closed))
                continue
            }
            if let heading = heading(trimmed) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    var cells = cells(row)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    var content = next.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if let first = listItem(line) {
                flush()
                var items = [first]
                i += 1
                while i < lines.count {
                    if let item = listItem(lines[i]) {
                        items.append(item)
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t") {
                        // An indented line that is not a new item continues the previous one.
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    i += 1
                }
                let ordered = first.marker.first?.isNumber == true
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    /// The inline markdown of one block: bold, italic, code spans, strikethrough and links.
    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// True for blocks that draw as running text. The Mac draws a run of them as one text view.
    public static func isTextBlock(_ block: Block) -> Bool {
        switch block {
        case .heading, .paragraph, .list, .quote: return true
        case .code, .table, .rule: return false
        }
    }

    private static func fence(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let run = trimmed.prefix { $0 == marker.first }
            return String(run)
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let parts = cells(trimmed)
        return !parts.isEmpty && parts.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(_ row: String) -> [String] {
        var row = row.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> ListItem? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let spaces = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(spaces)
        var marker = ""
        if let first = rest.first, "-*+".contains(first) {
            marker = String(first)
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let after = rest.dropFirst(digits.count).first
            guard after == "." || after == ")" else { return nil }
            marker = String(digits) + "."
        }
        let afterMarker = rest.dropFirst(marker.first?.isNumber == true ? marker.count : 1)
        guard afterMarker.first == " " else { return nil }
        return ListItem(indent: spaces / 2, marker: marker, text: afterMarker.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: Long messages

/// Decides how much of a long user message the transcript draws, with the Mac's limits.
public enum ChatMessageCollapse {
    /// A message collapses when it has more than this many characters or lines.
    public static let maxCharacters = 1_500
    public static let maxLines = 30
    /// A collapsed message shows at most this many characters and lines of its start.
    public static let previewCharacters = 600
    public static let previewLines = 12

    public struct Preview: Equatable, Sendable {
        public let text: String
        /// Counted in UTF-16 units, as the Mac counts them.
        public let hiddenCharacters: Int
    }

    /// The visible start of `text`, or nil when the message is short enough to draw in full.
    public static func preview(of text: String) -> Preview? {
        let head = text.prefix(maxCharacters + 1)
        let overCharacters = head.count > maxCharacters
        // Over the line limit means more than maxLines lines, so text must follow the maxLines-th line break.
        var overLines = false
        var newlines = 0
        for index in head.indices where head[index].isNewline {
            newlines += 1
            if newlines == maxLines {
                overLines = text.index(after: index) < text.endIndex
                break
            }
        }
        guard overCharacters || overLines else { return nil }

        var cut = text.prefix(previewCharacters)
        if cut.count == previewCharacters, !text.dropFirst(previewCharacters).isEmpty {
            // Back up to a line break, else a space, unless that would discard most of the preview.
            let floor = previewCharacters / 2
            if let index = cut.lastIndex(where: \.isNewline), cut.distance(from: cut.startIndex, to: index) >= floor {
                cut = cut[..<index]
            } else if let index = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: index) >= floor {
                cut = cut[..<index]
            }
        }
        var lines = 0
        if let index = cut.firstIndex(where: { if $0.isNewline { lines += 1 }; return lines >= previewLines }) {
            cut = cut[..<index]
        }
        let shown = String(cut)
        return Preview(text: shown, hiddenCharacters: max(0, text.utf16.count - shown.utf16.count))
    }
}

// MARK: Tool steps

/// Consecutive tool steps draw as one folded line, and every other item draws alone.
public enum RemoteTranscriptGroup: Identifiable, Equatable, Sendable {
    case item(RemoteChatItem)
    case tools([RemoteChatItem])

    public var id: String {
        switch self {
        case .item(let item): return item.id
        case .tools(let items): return items[0].id
        }
    }

    public static func make(_ items: [RemoteChatItem]) -> [RemoteTranscriptGroup] {
        var groups: [RemoteTranscriptGroup] = []
        var run: [RemoteChatItem] = []
        for item in items {
            if item.kind == "tool" {
                run.append(item)
            } else {
                if !run.isEmpty { groups.append(.tools(run)); run = [] }
                groups.append(.item(item))
            }
        }
        if !run.isEmpty { groups.append(.tools(run)) }
        return groups
    }
}

/// The line above a run of tool steps: "Ran 3 commands, read 2 files", or the step in flight.
public enum ChatToolSteps {
    public enum State: Equatable, Sendable { case running, failed, done }

    public static func state(_ steps: [RemoteChatItem]) -> State {
        if steps.contains(where: { $0.ok == nil }) { return .running }
        if steps.contains(where: { $0.ok == false }) { return .failed }
        return .done
    }

    /// While collapsed and a step is still in flight, the header shows that step. Otherwise it counts the steps by kind.
    public static func header(_ steps: [RemoteChatItem], expanded: Bool) -> String {
        if !expanded, let running = steps.last(where: { $0.ok == nil }) { return running.text ?? "" }
        var counts: [(verb: String, noun: String, count: Int)] = []
        for step in steps {
            let (verb, noun) = kind(of: step.text ?? "")
            if let i = counts.firstIndex(where: { $0.verb == verb }) { counts[i].count += 1 } else { counts.append((verb, noun, 1)) }
        }
        let parts = counts.map { "\($0.verb) \($0.count) \($0.noun)\($0.count == 1 ? "" : "s")" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func kind(of summary: String) -> (String, String) {
        let first = summary.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        switch first {
        case "ran": return ("ran", "command")
        case "read": return ("read", "file")
        case "edited", "wrote", "created": return ("edited", "file")
        case "deleted": return ("deleted", "file")
        case "searched", "grepped", "listed", "found": return ("searched", "time")
        default: return ("used", "tool")
        }
    }
}

// MARK: Notices

/// A system notice: the first line is the label, and the rest shows when the row is expanded.
public struct ChatNotice: Equatable, Sendable {
    public let label: String
    public let detail: String

    public init(_ text: String) {
        label = text.components(separatedBy: "\n").first ?? text
        detail = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Following the end

/// Whether the transcript follows new content, and whether to offer "Jump to latest". Same rule as the Mac's `TranscriptFollow`:
/// only the reader's own scrolling unpins. Content that grows, or a viewport that shrinks for the keyboard, moves the distance from
/// the bottom without the reader scrolling.
public struct TranscriptFollowState: Equatable, Sendable {
    public private(set) var pinned = true
    /// New content arrived below the viewport while the reader was scrolled up.
    public private(set) var newBelow = false
    private var lastContentHeight: Double?
    private var lastViewportHeight: Double?

    public static let bottomTolerance = 24.0

    public init() {}

    /// `userDriven`: a finger is dragging the scroll view. Without it, a change counts as the reader's only when the content and the
    /// viewport kept their size and the distance from the bottom still grew.
    public mutating func measure(contentHeight: Double, viewportHeight: Double, distanceFromBottom: Double, userDriven: Bool = false) {
        let atBottom = distanceFromBottom <= Self.bottomTolerance
        let sameSize = contentHeight == lastContentHeight && viewportHeight == lastViewportHeight
        if atBottom {
            pinned = true
        } else if userDriven || sameSize {
            pinned = false
        }
        lastContentHeight = contentHeight
        lastViewportHeight = viewportHeight
        if pinned { newBelow = false }
    }

    /// Sending a message jumps to the end and follows from there.
    public mutating func sent() {
        pinned = true
        newBelow = false
    }

    public mutating func jumpedToLatest() { sent() }

    /// New items or streamed text arrived. `readerSent`: the change is a message the reader just sent from here.
    public mutating func contentArrived(readerSent: Bool) {
        if readerSent { sent() }
        if !pinned { newBelow = true }
    }
}
