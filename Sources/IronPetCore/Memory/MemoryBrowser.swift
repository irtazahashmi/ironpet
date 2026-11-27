import Foundation

/// The Memory section's read side: the page list with its filter chips and search, one page in full, and the stack of pages the
/// user has followed. Foundation only, so the Mac window and the remote API show the same rows. The store does the writing.

/// The chips over the list. A chip narrows the list to one kind of page; All also holds the user's own page.
package enum MemoryFilter: String, CaseIterable, Codable, Sendable {
    case all, people, projects, organizations, topics, tools

    package var title: String {
        switch self {
        case .all: return "All"
        case .people: return "People"
        case .projects: return "Projects"
        case .organizations: return "Organizations"
        case .topics: return "Topics"
        case .tools: return "Tools"
        }
    }

    /// The plural of what the chip holds, for "4 of 26 people".
    package var noun: String {
        switch self {
        case .all: return "pages"
        case .people: return "people"
        case .projects: return "projects"
        case .organizations: return "organizations"
        case .topics: return "topics"
        case .tools: return "tools"
        }
    }

    package func includes(_ type: EntityType) -> Bool {
        switch self {
        case .all: return true
        case .people: return type == .person
        case .projects: return type == .project
        case .organizations: return type == .org
        case .topics: return type == .topic
        case .tools: return type == .tool
        }
    }
}

extension EntityType {
    /// The badge text of a page's type.
    package var label: String {
        switch self {
        case .me: return "Me"
        case .person: return "Person"
        case .project: return "Project"
        case .org: return "Organization"
        case .tool: return "Tool"
        case .topic: return "Topic"
        }
    }
}

/// One row of the list.
package struct MemoryRow: Equatable, Identifiable {
    package let id: String
    package let ref: String
    package let type: EntityType
    /// "About me" for the user's page, the entity's name otherwise.
    package let name: String
    /// The pinned fact, else the newest. While searching, the best match among the facts when the name does not match.
    package let summary: String
    package let factCount: Int
    /// The day of the newest fact.
    package let updated: Date?
    package let aliases: [String]
    package let identifiers: [String]
    /// Every valid fact's text, newest first, for the search.
    package let facts: [String]
    /// True when the search matched in a fact and not in the name, aliases or identifiers.
    package let matchedInFact: Bool

    func with(summary: String, matchedInFact: Bool) -> MemoryRow {
        MemoryRow(id: id, ref: ref, type: type, name: name, summary: summary, factCount: factCount, updated: updated, aliases: aliases,
                  identifiers: identifiers, facts: facts, matchedInFact: matchedInFact)
    }
}

/// What the list shows for a filter and a search.
package struct MemoryList: Equatable {
    package let rows: [MemoryRow]
    /// How many pages the filter holds before the search.
    package let total: Int
    package let filter: MemoryFilter
    package let query: String

    package var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// "34 pages", or "4 of 26 people" while searching.
    package var countLabel: String {
        if searching { return "\(rows.count) of \(total) \(filter.noun)" }
        return "\(total) \(total == 1 && filter == .all ? "page" : filter.noun)"
    }
}

package enum MemoryBrowser {
    /// Whether `needle` is in `text`, ignoring case and accents, the rule `ListSearch` uses.
    package static func contains(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The rows of every page that has a fact or a recorded mention, newest update first. A page with neither stays out.
    package static func rows(entities: [MemoryEntity], claims: [String: [MemoryClaim]]) -> [MemoryRow] {
        entities.compactMap { entity -> MemoryRow? in
            let facts = claims[entity.id] ?? []
            // A person seen once is a stub and stays out of the list until a second source or a fact, so one-off names do not fill it.
            guard !facts.isEmpty || (!entity.sources.isEmpty && !entity.isStub) else { return nil }
            let shown = facts.first(where: \.pinned) ?? facts.first
            let mentioned = "Mentioned in \(entity.sources.count) place\(entity.sources.count == 1 ? "" : "s"), no notes yet."
            return MemoryRow(id: entity.id, ref: entity.ref, type: entity.type, name: entity.type == .me ? "About me" : entity.name,
                             summary: shown?.text ?? mentioned, factCount: facts.count, updated: day(facts.map(\.date).max() ?? ""),
                             aliases: entity.aliases, identifiers: entity.identifiers, facts: facts.map(\.text), matchedInFact: false)
        }
        .sorted { a, b in
            switch (a.updated, b.updated) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The list for a filter and a search. Pages whose name, aliases or identifiers match come first, then pages that only mention
    /// the text in a fact, each group keeping the newest-first order.
    package static func list(_ rows: [MemoryRow], filter: MemoryFilter, query: String) -> MemoryList {
        let inFilter = rows.filter { filter.includes($0.type) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return MemoryList(rows: inFilter, total: inFilter.count, filter: filter, query: query) }
        var byName: [MemoryRow] = []
        var byFact: [MemoryRow] = []
        for row in inFilter {
            if ([row.name] + row.aliases + row.identifiers).contains(where: { contains($0, needle) }) {
                byName.append(row.with(summary: row.facts.first(where: { contains($0, needle) }) ?? row.summary, matchedInFact: false))
            } else if let fact = row.facts.first(where: { contains($0, needle) }) {
                byFact.append(row.with(summary: fact, matchedInFact: true))
            }
        }
        // A name match keeps its own summary unless the summary itself holds no match and a fact does.
        let named = byName.map { row -> MemoryRow in
            let original = inFilter.first { $0.id == row.id }
            if let original, contains(original.summary, needle) { return row.with(summary: original.summary, matchedInFact: false) }
            return row
        }
        return MemoryList(rows: named + byFact, total: inFilter.count, filter: filter, query: query)
    }

    /// How many pages of each other filter match, for "3 people match".
    package static func otherMatches(_ rows: [MemoryRow], query: String, excluding filter: MemoryFilter) -> [(filter: MemoryFilter, count: Int)] {
        MemoryFilter.allCases.filter { $0 != .all && $0 != filter }.compactMap { other in
            let count = list(rows, filter: other, query: query).rows.count
            return count > 0 ? (other, count) : nil
        }
    }

    static func day(_ text: String) -> Date? {
        guard MemoryNote.isDay(text) else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Page detail

/// One link of a page, seen from that page: the page at the other end.
package struct MemoryLinkItem: Equatable, Identifiable {
    package var id: String { "\(group)/\(page)" }
    package let group: String
    package let page: String
    package let ref: String
    package let name: String
    package let type: EntityType
    package let count: Int
    package let lastSeen: Date
}

/// The links of one kind, such as "Worked on by".
package struct MemoryLinkGroup: Equatable, Identifiable {
    package var id: String { title }
    package let title: String
    package let items: [MemoryLinkItem]
}

/// A page in full.
package struct MemoryDetail: Equatable {
    package let entity: MemoryEntity
    /// "About me" for the user's page.
    package let title: String
    /// The valid facts: the pinned ones first, then newest first.
    package let facts: [MemoryClaim]
    /// The facts a newer one replaced, newest replaced first.
    package let earlier: [MemoryClaim]
    package let linkGroups: [MemoryLinkGroup]
    /// Other people pages that may be the same person, as `(id, name, fact count)`.
    package let possibleDuplicates: [MemoryDuplicate]

    package var pinnedCount: Int { facts.filter(\.pinned).count }
    package var updated: Date? { MemoryBrowser.day(facts.map(\.date).max() ?? "") }
    package var firstSeen: Date? { MemoryBrowser.day((facts + earlier).map(\.date).filter { !$0.isEmpty }.min() ?? "") }
    package var linkCount: Int { linkGroups.reduce(0) { $0 + $1.items.count } }

    /// The page as Markdown, for Export page.
    package var markdown: String {
        var lines = ["# \(title)", "", "Type: \(entity.type.label)"]
        if !entity.aliases.isEmpty { lines.append("Also known as: " + entity.aliases.joined(separator: ", ")) }
        if !entity.identifiers.isEmpty { lines.append("Identifiers: " + entity.identifiers.joined(separator: ", ")) }
        if !entity.sources.isEmpty { lines.append("Mentioned in: " + entity.sources.joined(separator: ", ")) }
        lines += ["", "## Facts", ""]
        lines += facts.map { "- " + $0.text + ($0.date.isEmpty ? "" : " (\($0.date))") + ($0.pinned ? " [pinned]" : "") }
        if !earlier.isEmpty {
            lines += ["", "## Earlier", ""]
            lines += earlier.map { "- ~~" + $0.text + "~~" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

package struct MemoryDuplicate: Equatable, Identifiable {
    package var id: String { page }
    package let page: String
    package let name: String
    package let facts: Int
}

extension MemoryLink {
    /// The heading of a link seen from `page`: "Works on" when the page is the source, "Worked on by" when it is the target.
    static func heading(_ type: String, outgoing: Bool) -> String {
        let table: [String: (String, String)] = [
            "works_on": ("Works on", "Worked on by"),
            "part_of": ("Part of", "Has parts"),
            "owns": ("Owns", "Owned by"),
            "uses": ("Uses", "Used by"),
            "knows": ("Knows", "Known by"),
            "reports_to": ("Reports to", "Manager of"),
            "member_of": ("Member of", "Has members"),
            "works_at": ("Works at", "Employs"),
        ]
        if let pair = table[type] { return outgoing ? pair.0 : pair.1 }
        let words = type.replacingOccurrences(of: "_", with: " ")
        let text = words.prefix(1).uppercased() + words.dropFirst()
        return outgoing ? text : "\(text) (from)"
    }
}

extension EntityMemoryStore {
    /// Every page that has a fact, as list rows.
    package func browseRows() -> [MemoryRow] {
        let all = entities()
        var claimsByPage: [String: [MemoryClaim]] = [:]
        for entity in all { claimsByPage[entity.id] = claims(of: entity.id) }
        return MemoryBrowser.rows(entities: all, claims: claimsByPage)
    }

    /// One page in full, by id or `page_` ref. Nil when it does not exist.
    package func detail(_ key: String) -> MemoryDetail? {
        let all = entities()
        guard let entity = all.first(where: { $0.id == key || $0.ref == key }) else { return nil }
        let valid = claims(of: entity.id)
        let facts = valid.filter(\.pinned) + valid.filter { !$0.pinned }
        var groups: [String: [MemoryLinkItem]] = [:]
        var order: [String] = []
        for link in pageLinks(of: entity.id) {
            let outgoing = link.from == entity.id
            let otherID = outgoing ? link.to : link.from
            guard let other = all.first(where: { $0.id == otherID }) else { continue }
            let heading = MemoryLink.heading(link.type, outgoing: outgoing)
            if groups[heading] == nil { order.append(heading) }
            groups[heading, default: []].append(MemoryLinkItem(group: heading, page: other.id, ref: other.ref,
                                                                name: other.type == .me ? "About me" : other.name, type: other.type,
                                                                count: link.count, lastSeen: link.lastSeen))
        }
        var duplicates: [MemoryDuplicate] = []
        // People that share a first name, and pages of any type whose names are variants of each other.
        let first = entity.type == .person ? Self.firstWord(entity.name) : nil
        for other in all where other.type == entity.type && other.id != entity.id {
            let sameFirst = first != nil && Self.firstWord(other.name) == first
            guard sameFirst || EntityMatcher.mayBeSame(entity.record, other.record) else { continue }
            let count = claims(of: other.id).count
            if count > 0 { duplicates.append(MemoryDuplicate(page: other.id, name: other.name, facts: count)) }
        }
        return MemoryDetail(entity: entity, title: entity.type == .me ? "About me" : entity.name, facts: facts, earlier: history(of: entity.id),
                            linkGroups: order.map { MemoryLinkGroup(title: $0, items: groups[$0] ?? []) }, possibleDuplicates: duplicates)
    }

    private static func firstWord(_ name: String) -> String? {
        name.split(separator: " ").first.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    }

    private func pageLinks(of entity: String) -> [MemoryLink] {
        (try? database.read {
            try $0.rows("""
                SELECT type, from_entity, to_entity, count, first_seen, last_seen, sources FROM memory_links
                WHERE from_entity = ? OR to_entity = ? ORDER BY last_seen DESC
                """, [entity, entity]).compactMap { row in
                guard let type = row[0] as? String, let from = row[1] as? String, let to = row[2] as? String else { return nil }
                return MemoryLink(type: type, from: from, to: to, count: Int(row[3] as? Int64 ?? 0),
                                  firstSeen: Date(timeIntervalSince1970: row[4] as? Double ?? 0),
                                  lastSeen: Date(timeIntervalSince1970: row[5] as? Double ?? 0), sources: [])
            }
        }) ?? []
    }

    /// Forgets one fact by id. It stays in the change log, so Undo can put it back.
    @discardableResult
    package func forgetClaim(_ id: Int64, source: String) -> Bool {
        guard let claim = claimIfValid(id) else { return false }
        return invalidate([claim], source: source)
    }

    /// Forgets every fact of a page and the links that touch it. The page stays, empty, so a later mention reuses it.
    @discardableResult
    package func forgetPage(_ key: String, source: String) -> Bool {
        guard let entity = entities().first(where: { $0.id == key || $0.ref == key }) else { return false }
        let valid = claims(of: entity.id)
        _ = try? database.write { db in
            try db.execute("DELETE FROM memory_links WHERE from_entity = ? OR to_entity = ?", [entity.id, entity.id])
            // A page that only records where it was mentioned leaves the list too.
            try db.execute("UPDATE memory_entities SET sources = '' WHERE id = ?", [entity.id])
        }
        return valid.isEmpty || invalidate(valid, source: source)
    }

    /// The valid fact with this public ref.
    package func claim(ref: String) -> MemoryClaim? {
        entities().lazy.flatMap { self.claims(of: $0.id) }.first { $0.ref == ref }
    }

    private func claimIfValid(_ id: Int64) -> MemoryClaim? {
        entities().lazy.flatMap { self.claims(of: $0.id) }.first { $0.id == id }
    }

    private func invalidate(_ claims: [MemoryClaim], source: String) -> Bool {
        let at = now()
        let all = entities()
        do {
            try database.write { db in
                for claim in claims {
                    try db.execute("UPDATE memory_claims SET invalid_at = ? WHERE id = ?", [at.timeIntervalSince1970, claim.id])
                }
            }
        } catch {
            return false
        }
        for claim in claims {
            let entity = all.first { $0.id == claim.entity }
            index.record(at: at, file: claim.entity, section: entity?.type == .person ? entity?.name : nil, action: .forgot,
                         note: claim.note.line, previous: String(claim.id), source: source, claim: claim.id)
            index.removeClaim(claim.id)
        }
        return true
    }
}

// MARK: - Navigation

/// The pages the user followed in Memory, oldest first. Empty means the list.
package struct MemoryNavigation: Equatable {
    package private(set) var stack: [String] = []

    package init(stack: [String] = []) { self.stack = stack }

    package var current: String? { stack.last }
    package var isOpen: Bool { !stack.isEmpty }

    /// Opens a page on top of the current one. Opening the page that is already on top changes nothing.
    package mutating func push(_ page: String) {
        if stack.last != page { stack.append(page) }
    }

    /// Goes back one page; from the first page it returns to the list.
    package mutating func back() { if !stack.isEmpty { stack.removeLast() } }

    /// Pops to the page at `index` of the trail, which stays open.
    package mutating func pop(to index: Int) {
        guard stack.indices.contains(index) else { return }
        stack.removeSubrange((index + 1)...)
    }

    /// Back to the list.
    package mutating func reset() { stack = [] }

    /// Drops pages that no longer exist, such as after a forget.
    package mutating func prune(keeping exists: (String) -> Bool) {
        if let bad = stack.firstIndex(where: { !exists($0) }) { stack.removeSubrange(bad...) }
    }
}
