import Foundation

/// The names and symbols of the places an inbox item can come from, by the kind's raw value (`chat`, `capture`, `meeting`).
public enum InboxKinds {
    public static func title(_ kind: String) -> String {
        switch kind {
        case "email": return "Email"
        case "pr": return "Pull request"
        case "meeting": return "Meeting"
        case "capture": return "Screen capture"
        case "chat": return "Chat"
        case "automation": return "Watcher"
        case "telegram": return "Telegram"
        case "cli": return "CLI"
        case "agent": return "Agent"
        case "user": return "You"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    public static func symbol(_ kind: String) -> String {
        switch kind {
        case "chat": return "bubble.left"
        case "telegram": return "paperplane"
        case "meeting": return SharedSymbols.meetings
        case "automation": return SharedSymbols.automations
        case "cli": return "terminal"
        case "agent": return "sparkles"
        case "user": return "person"
        case "capture": return "text.viewfinder"
        case "email": return "envelope"
        case "pr": return "arrow.triangle.pull"
        default: return SharedSymbols.tasks
        }
    }
}

/// The items of one origin kind.
public struct InboxGroup<Item> {
    public var kind: String
    public var items: [Item]
    public var title: String { InboxKinds.title(kind) }
    public var symbol: String { InboxKinds.symbol(kind) }
}

extension InboxGroup: Equatable where Item: Equatable {}

public enum InboxGrouping {
    /// Groups the open items by origin kind. Inside a group the newest item comes first, and the groups are ordered by their newest
    /// item, so the group that changed last is on top. Items with the same time keep the order of `tie`, larger first.
    public static func group<Item>(_ items: [Item], kind: (Item) -> String, created: (Item) -> Date, tie: (Item) -> String) -> [InboxGroup<Item>] {
        let newestFirst = items.sorted { (created($0), tie($0)) > (created($1), tie($1)) }
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for item in newestFirst {
            let key = kind(item)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { InboxGroup(kind: $0, items: groups[$0] ?? []) }
    }

    /// The chat thread id in a source reference such as `chat:7B2F...`. Nil for any other reference.
    public static func chatThread(ref: String) -> String? {
        guard ref.hasPrefix("chat:") else { return nil }
        let id = String(ref.dropFirst("chat:".count))
        return id.isEmpty ? nil : id
    }

    /// The other places an item came from, as the row says them: "and Agent". Nil when there is no other place. A place with the
    /// same name as the first is not repeated.
    public static func otherSources(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        var others: [String] = []
        for name in names.dropFirst() where name != first && !others.contains(name) { others.append(name) }
        return others.isEmpty ? nil : "and " + others.joined(separator: ", ")
    }
}

/// The line under an item's title: why the item exists, with the chat it came from as a link, and when it arrived.
public struct InboxOriginLine: Equatable {
    public enum Segment: Equatable {
        case text(String)
        /// The word "chat", which opens the chat thread.
        case chat(thread: String)
    }

    public var segments: [Segment]
    public var symbol: String

    /// `reason` is the reason stored with the item. Without one the line says "From a" and the kind of the first source, such as "From a
    /// chat". With a chat thread, the first word "chat" of the line is the link; a reason that never says "chat" gets it added after.
    public static func make(reason: String?, kind: String, chatThread: String?) -> InboxOriginLine {
        let stored = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = stored.isEmpty ? "From a " + InboxKinds.title(kind).lowercased() : stored
        let symbol = InboxKinds.symbol(kind)
        guard let thread = chatThread else { return InboxOriginLine(segments: [.text(text)], symbol: symbol) }
        if let range = wordRange("chat", in: text) {
            var segments: [Segment] = []
            let before = String(text[..<range.lowerBound]), after = String(text[range.upperBound...])
            if !before.isEmpty { segments.append(.text(before)) }
            segments.append(.chat(thread: thread))
            if !after.isEmpty { segments.append(.text(after)) }
            return InboxOriginLine(segments: segments, symbol: symbol)
        }
        return InboxOriginLine(segments: [.text(text + " in a "), .chat(thread: thread)], symbol: symbol)
    }

    /// The line as plain text, with the time after it: "Found by the inbox scan in a chat between the user and Bunny, 27 Nov, 15:04".
    public func plain(time: String) -> String {
        let words = segments.map { segment -> String in
            switch segment {
            case .text(let text): return text
            case .chat: return "chat"
            }
        }
        return words.joined() + ", " + time
    }

    private static func wordRange(_ word: String, in text: String) -> Range<String.Index>? {
        var from = text.startIndex
        while let range = text.range(of: word, options: [.caseInsensitive], range: from..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == text.endIndex || !text[range.upperBound].isLetter
            if beforeOK, afterOK { return range }
            from = range.upperBound
        }
        return nil
    }
}

/// One row of an item page's Sources section.
public struct InboxSourceRow: Equatable {
    public enum Action: Equatable {
        case showChat(thread: String)
        case openURL(URL)
        /// The meeting folder's name, which the Mac opens in its transcripts.
        case openMeeting(folder: String)
        case none
    }

    public var symbol: String
    public var title: String
    public var action: Action
    /// What the link says: "Show chat", "Show meeting", or the address without its scheme.
    public var actionTitle: String?

    public struct Input: Equatable {
        public init(kind: String, ref: String, url: String?, label: String?) {
            self.kind = kind; self.ref = ref; self.url = url; self.label = label
        }

        public var kind: String
        public var ref: String
        public var url: String?
        public var label: String?
    }

    /// One row per source. A source with a web page links to it. A chat source links to its thread and a meeting source to its folder.
    /// A source that names only an id has no link, because an id on its own tells the reader nothing.
    public static func rows(_ sources: [Input]) -> [InboxSourceRow] {
        sources.map { source in
            let title = source.label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? InboxKinds.title(source.kind)
            let symbol = InboxKinds.symbol(source.kind)
            if let thread = InboxGrouping.chatThread(ref: source.ref), source.kind == "chat" {
                return InboxSourceRow(symbol: symbol, title: title, action: .showChat(thread: thread), actionTitle: "Show chat")
            }
            if let raw = source.url, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               url.host?.isEmpty == false {
                return InboxSourceRow(symbol: symbol, title: title, action: .openURL(url), actionTitle: display(url))
            }
            if source.kind == "meeting", source.ref.hasPrefix("/") {
                return InboxSourceRow(symbol: symbol, title: title, action: .openMeeting(folder: (source.ref as NSString).lastPathComponent),
                                      actionTitle: "Show meeting")
            }
            return InboxSourceRow(symbol: symbol, title: title, action: .none, actionTitle: nil)
        }
    }

    /// An address as one short line: the host and the path, with no scheme, query or trailing slash.
    public static func display(_ url: URL) -> String {
        var text = url.host ?? url.absoluteString
        let path = url.path
        if path.count > 1 { text += path.hasSuffix("/") ? String(path.dropLast()) : path }
        return text
    }
}

/// The link on the word "chat" in an item's origin line. A web page cannot open an IronPet chat, so the link has its own scheme, and
/// the page catches it with an `openURL` action and opens the thread.
public enum InboxChatLink {
    public static let scheme = "ironpet-chat"

    public static func url(thread: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "thread", value: thread)]
        return parts.url
    }

    public static func thread(from url: URL) -> String? {
        guard url.scheme == scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let thread = parts.queryItems?.first { $0.name == "thread" }?.value
        return thread?.isEmpty == false ? thread : nil
    }

    /// The origin line and the time as one run of text, with the chat as a link.
    public static func text(_ line: InboxOriginLine, time: String) -> AttributedString {
        var result = AttributedString()
        for segment in line.segments {
            switch segment {
            case .text(let text): result += AttributedString(text)
            case .chat(let thread):
                var link = AttributedString("chat")
                link.link = url(thread: thread)
                result += link
            }
        }
        result += AttributedString(", " + time)
        return result
    }
}
