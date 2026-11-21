import Foundation

/// Block-level markdown for agent replies. SwiftUI's `Text` only renders inline markdown (bold, code,
/// links), so headings, lists, quotes, code blocks, tables and rules are split out here and inline
/// markdown inside each block still goes through `AttributedString(markdown:)`.
package enum Markdown {
    package struct ListItem: Equatable {
        package init(indent: Int, marker: String, text: String) {
            self.indent = indent
            self.marker = marker
            self.text = text
        }

        package var indent: Int
        package var marker: String
        package var text: String

        /// `- [ ] todo` and `- [x] done` render as checkboxes.
        package var task: (done: Bool, text: String)? {
            for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(prefix) {
                return (done, String(text.dropFirst(prefix.count)))
            }
            return nil
        }
    }

    package enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(ordered: Bool, items: [ListItem])
        case quote(String)
        /// `closed` is false while a reply is still streaming the block; a diagram renders only once closed.
        case code(language: String?, text: String, closed: Bool)
        case table(header: [String], rows: [[String]])
        case rule
    }

    /// The text each block draws, in order, for search. Closed mermaid diagrams render as an image and have none.
    package static func segments(of block: Block) -> [String] {
        func shown(_ markdown: String) -> String { String(parseInline(markdown).characters) }
        switch block {
        case .heading(_, let text), .paragraph(let text), .quote(let text):
            return [shown(text)]
        case .list(_, let items):
            return items.map { shown($0.task?.text ?? $0.text) }
        case .code(let language, let text, let closed):
            return language?.lowercased() == "mermaid" && closed ? [] : [text]
        case .table(let header, let rows):
            return (header + rows.flatMap { $0 }).map(shown)
        case .rule:
            return []
        }
    }

    package static func segments(of text: String) -> [String] {
        parse(text).flatMap { segments(of: $0) }
    }

    package static func parse(_ text: String) -> [Block] {
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

    package static func parseInline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
