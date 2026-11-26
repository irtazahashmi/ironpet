import Foundation

/// One server-sent event: its `event:` name, when it has one, and its `data:` text.
public struct SSEEvent: Equatable, Sendable {
    public var name: String?
    public var data: String
}

/// Reads server-sent events from lines of text, as `URLSession.AsyncBytes.lines` yields them. A blank line ends an event. Comment lines
/// start with a colon and are skipped.
public struct SSEParser: Sendable {
    private var name: String?
    private var data: [String] = []

    public init() {}

    /// Feeds one line. Returns the event the line completed, if it did.
    public mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { name = nil; data = [] }
            guard !data.isEmpty else { return nil }
            return SSEEvent(name: name, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            value = rest
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// Ends the stream. A last event with no blank line after it still counts.
    public mutating func finish() -> SSEEvent? { feed("") }
}
