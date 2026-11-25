import Foundation

// MARK: Memory

/// One row of `GET /v1/memory`. `id` is the page's public `page_` ref.
public struct RemoteMemoryRow: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var typeLabel: String
    public var name: String
    public var summary: String
    public var factCount: Int
    public var updated: Date?
    /// The search matched a fact and not the name.
    public var matchedInFact: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, name, summary, updated
        case typeLabel = "type_label"
        case factCount = "fact_count"
        case matchedInFact = "matched_in_fact"
    }

    public init(id: String, type: String, typeLabel: String, name: String, summary: String, factCount: Int, updated: Date? = nil,
                matchedInFact: Bool = false) {
        self.id = id; self.type = type; self.typeLabel = typeLabel; self.name = name; self.summary = summary
        self.factCount = factCount; self.updated = updated; self.matchedInFact = matchedInFact
    }
}

/// `GET /v1/memory?filter=<chip>&q=<search>`.
public struct RemoteMemoryList: Codable, Equatable, Sendable {
    public var pages: [RemoteMemoryRow]
    /// How many pages the chip holds before the search.
    public var total: Int
    /// "34 pages", or "4 of 26 people" while searching.
    public var countLabel: String
    /// For an empty search result: how many pages of another chip match, as `chip: count`.
    public var otherMatches: [String: Int]

    enum CodingKeys: String, CodingKey {
        case pages, total
        case countLabel = "count_label"
        case otherMatches = "other_matches"
    }

    public init(pages: [RemoteMemoryRow], total: Int, countLabel: String, otherMatches: [String: Int] = [:]) {
        self.pages = pages; self.total = total; self.countLabel = countLabel; self.otherMatches = otherMatches
    }
}

public struct RemoteMemoryFact: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The `claim_` ref.
    public var id: String
    public var text: String
    /// `yyyy-MM-dd`; empty for a note written by hand.
    public var date: String
    public var pinned: Bool
    /// Where it was said, such as `chat:<id>` or `meeting:<id>`.
    public var sources: [String]
    /// When a replaced fact stopped holding.
    public var replaced: Date?

    public init(id: String, text: String, date: String, pinned: Bool, sources: [String], replaced: Date? = nil) {
        self.id = id; self.text = text; self.date = date; self.pinned = pinned; self.sources = sources; self.replaced = replaced
    }
}

public struct RemoteMemoryLink: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The linked page's `page_` ref.
    public var id: String
    public var name: String
    public var type: String
    public var typeLabel: String
    public var mentions: Int
    public var lastSeen: Date

    enum CodingKeys: String, CodingKey {
        case id, name, type, mentions
        case typeLabel = "type_label"
        case lastSeen = "last_seen"
    }

    public init(id: String, name: String, type: String, typeLabel: String, mentions: Int, lastSeen: Date) {
        self.id = id; self.name = name; self.type = type; self.typeLabel = typeLabel; self.mentions = mentions; self.lastSeen = lastSeen
    }
}

public struct RemoteMemoryLinkGroup: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { title }
    public var title: String
    public var links: [RemoteMemoryLink]
    public init(title: String, links: [RemoteMemoryLink]) { self.title = title; self.links = links }
}

/// `GET /v1/memory/pages/<ref>`.
public struct RemoteMemoryPage: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var typeLabel: String
    public var title: String
    public var aliases: [String]
    public var identifiers: [String]
    /// Pinned first, then newest first.
    public var facts: [RemoteMemoryFact]
    public var earlier: [RemoteMemoryFact]
    public var linkGroups: [RemoteMemoryLinkGroup]
    public var updated: Date?
    public var firstSeen: Date?

    enum CodingKeys: String, CodingKey {
        case id, type, title, aliases, identifiers, facts, earlier, updated
        case typeLabel = "type_label"
        case linkGroups = "link_groups"
        case firstSeen = "first_seen"
    }

    public init(id: String, type: String, typeLabel: String, title: String, aliases: [String] = [], identifiers: [String] = [],
                facts: [RemoteMemoryFact] = [], earlier: [RemoteMemoryFact] = [], linkGroups: [RemoteMemoryLinkGroup] = [],
                updated: Date? = nil, firstSeen: Date? = nil) {
        self.id = id; self.type = type; self.typeLabel = typeLabel; self.title = title; self.aliases = aliases
        self.identifiers = identifiers; self.facts = facts; self.earlier = earlier; self.linkGroups = linkGroups
        self.updated = updated; self.firstSeen = firstSeen
    }
}

/// The chips over the list, in order. The raw value is the `filter` query value.
public enum RemoteMemoryFilter: String, CaseIterable, Sendable {
    case all, people, projects, organizations, topics, tools

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

extension IronPetClient {
    public func memory(filter: RemoteMemoryFilter = .all, query: String = "") async throws -> RemoteMemoryList {
        var items = [URLQueryItem(name: "filter", value: filter.rawValue)]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        return try await get(RemoteMemoryList.self, APIPath.memory, query: items)
    }

    public func memoryPage(id: String) async throws -> RemoteMemoryPage { try await get(RemoteMemoryPage.self, APIPath.memoryPage(id)) }

    public func pinMemoryFact(id: String, pinned: Bool) async throws {
        try await post(APIPath.memoryFactPin(id), json: ["pinned": pinned])
    }

    public func forgetMemoryFact(id: String) async throws { _ = try await perform(request("DELETE", APIPath.memoryFact(id))) }

    public func forgetMemoryPage(id: String) async throws { _ = try await perform(request("DELETE", APIPath.memoryPage(id))) }
}

// MARK: Sources

/// Where a fact came from, as the chip under it shows. The Mac and the phone read the same `sources` strings.
public struct MemorySource: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case chat, meeting, task, screen, automation, user, other }

    public let kind: Kind
    public let label: String
    /// What the chip opens: a meeting folder name, an automation id; nil when it opens the whole section.
    public let target: String?
    public let symbol: String

    public init(_ source: String) {
        func rest(_ prefix: String) -> String? { source.hasPrefix(prefix) ? String(source.dropFirst(prefix.count)) : nil }
        if rest("chat:") != nil { self = Self.make(.chat, "Chat", nil, "bubble.left") }
        else if let folder = rest("meeting:") { self = Self.make(.meeting, "Meeting", folder, "person.2.wave.2") }
        else if source == "tasks" || rest("task:") != nil { self = Self.make(.task, "Task", rest("task:"), "checkmark.circle") }
        else if source == "screen" { self = Self.make(.screen, "Screen review", nil, "display") }
        else if let id = rest("automation:") { self = Self.make(.automation, "Automation", id, "clock") }
        else if source == "user" { self = Self.make(.user, "You", nil, "person") }
        else { self = Self.make(.other, "Agent", nil, "sparkles") }
    }

    private static func make(_ kind: Kind, _ label: String, _ target: String?, _ symbol: String) -> MemorySource {
        MemorySource(kind: kind, label: label, target: target, symbol: symbol)
    }

    private init(kind: Kind, label: String, target: String?, symbol: String) {
        self.kind = kind; self.label = label; self.target = target; self.symbol = symbol
    }

    /// The chips under a fact: one per kind, in the order the sources were said.
    public static func chips(_ sources: [String]) -> [MemorySource] {
        var seen = Set<Kind>()
        return sources.map(MemorySource.init).filter { seen.insert($0.kind).inserted }
    }
}

/// How a day reads in the Memory lists: Today, Yesterday, or the date.
public enum MemoryDay {
    public static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }

    /// `yyyy-MM-dd` as a date, nil for anything else.
    public static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
