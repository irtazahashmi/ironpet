#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A dated line of what Ghost knows about an entity, with the sources that said it. A claim that stops being true keeps its row with
/// `invalidAt` set, so it leaves the page and stays in its history.
package struct MemoryClaim: Equatable, Identifiable, Codable {
    package let id: Int64
    package let entity: String
    package let text: String
    /// `yyyy-MM-dd`, the day it was last said. Empty for a note a person wrote by hand.
    package let date: String
    package let sources: [String]
    /// When the claim stopped holding. Nil while it holds.
    package let invalidAt: Date?
    /// A pinned claim is never replaced, and a claim that would replace it is added beside it instead.
    package let pinned: Bool

    package var note: MemoryNote {
        MemoryNote(text: text, date: date.isEmpty ? nil : date, source: sources.last ?? MemoryNote.userSource)
    }
}

/// An entity's page: who or what it is, and how it is named.
package struct MemoryEntity: Equatable, Identifiable, Codable {
    package let id: String
    package let type: EntityType
    package let name: String
    package let aliases: [String]
    package let identifiers: [String]
    /// How many times it has come up. A new entity is a stub until it has come up `EntityMemoryStore.stubMentions` times.
    package let mentions: Int

    package var isStub: Bool { type == .person && mentions < EntityMemoryStore.stubMentions }
    package var record: EntityRecord { EntityRecord(id: id, type: type, name: name, aliases: aliases, identifiers: identifiers) }
}

/// A typed link from one entity to another, such as `works_on`.
package struct MemoryLink: Equatable {
    package let type: String
    package let from: String
    package let to: String
    package let count: Int
    package let firstSeen: Date
    package let lastSeen: Date
    package let sources: [String]
}

/// One entity with its valid claims (newest first) and its links.
package struct EntityPage: Equatable {
    package let entity: MemoryEntity
    package let claims: [MemoryClaim]
    package let links: [MemoryLink]
}

/// Ghost's memory as entity pages in `ironpet.db`. An entity (the user, a person, a project) has dated claims, and links to other
/// entities. A claim that a newer one makes wrong is replaced: the old one is invalidated, not deleted, so Undo and history can show it.
/// The chat preamble, the memory tools, the learning pass and Settings all read and write through here.
@MainActor
package final class EntityMemoryStore: MemoryStore {
    /// How many times a person must come up before the preamble names them unasked, so one-off names stay out.
    package nonisolated static let stubMentions = 2
    /// Where Export writes Markdown copies of the pages. Read at each export, so a test can point it at a temp folder.
    package nonisolated(unsafe) static var exportDirectory = Paths.root.appendingPathComponent("memory-export")

    private static var current: EntityMemoryStore?
    /// The app's store. `AppDelegate` sets it once the database is open. A store asked for before that runs in memory.
    package static var shared: EntityMemoryStore {
        get {
            if let current { return current }
            let store = EntityMemoryStore(database: Database.open(path: nil, migrations: MemoryIndex.migrations).database)
            current = store
            return store
        }
        set { current = newValue }
    }

    package let database: Database
    package let index: MemoryIndex
    package var now: () -> Date = Date.init
    package var calendar = Calendar.current

    package init(database: Database, index: MemoryIndex? = nil) {
        self.database = database
        self.index = index ?? MemoryIndex(database: database)
        ensureMe()
    }

    /// Where a write goes: the page it lands on and how the page is titled.
    private struct Target {
        let id: String
        let type: EntityType
        let name: String
        let identifiers: [String]
        /// The person a claim is about, for a people note.
        let person: String?
    }

    /// What a write did, as the transaction left it.
    private struct Written {
        let claim: Int64
        let removed: [MemoryClaim]
        let note: MemoryNote
        let target: Target
        let bumped: Bool
    }

    // MARK: Reading

    /// Every entity, the user's page first, then people, projects and the rest by name.
    package func entities() -> [MemoryEntity] {
        let rows = (try? database.read { try Self.entityRows($0) }) ?? []
        return rows.sorted { a, b in
            if (a.type == .me) != (b.type == .me) { return a.type == .me }
            if a.type.sortRank != b.type.sortRank { return a.type.sortRank < b.type.sortRank }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Every entity's record, for the matcher.
    private func records() -> [EntityRecord] {
        ((try? database.read { try Self.entityRows($0) }) ?? []).map(\.record)
    }

    /// The valid claims of one entity, newest first.
    package func claims(of entity: String) -> [MemoryClaim] {
        (try? database.read { try Self.claims($0, where: "entity = ? AND invalid_at IS NULL", [entity]) }) ?? []
    }

    /// The claims of one entity that stopped holding, newest first. They are what Undo and the history show.
    package func history(of entity: String) -> [MemoryClaim] {
        (try? database.read { try Self.claims($0, where: "entity = ? AND invalid_at IS NOT NULL", order: "invalid_at DESC, id DESC", [entity]) }) ?? []
    }

    /// A page by name, alias or identifier. Ambiguous or unknown names are refused rather than guessed.
    package func page(_ name: String) -> Result<EntityPage, MemoryError> {
        switch EntityMatcher.match(name: name, identifiers: [name], in: records()) {
        case .found(let id):
            guard let entity = entities().first(where: { $0.id == id }) else { return .failure(MemoryError(message: "no page named \(name)")) }
            return .success(EntityPage(entity: entity, claims: claims(of: id), links: links(of: id)))
        case .none:
            return .failure(MemoryError(message: "no page named \(name) yet"))
        case .ambiguous(let ids):
            return .failure(MemoryError(message: "more than one page matches \(name): \(names(ids).joined(separator: ", ")). Say which."))
        }
    }

    /// The links of one entity, in either direction, optionally of one type.
    package func links(_ name: String, type: String?) -> Result<[MemoryLink], MemoryError> {
        switch page(name) {
        case .failure(let failure): return .failure(failure)
        case .success(let page):
            return .success(links(of: page.entity.id).filter { type == nil || $0.type == type })
        }
    }

    private func links(of entity: String) -> [MemoryLink] {
        (try? database.read {
            try $0.rows("""
                SELECT type, from_entity, to_entity, count, first_seen, last_seen, sources FROM memory_links
                WHERE from_entity = ? OR to_entity = ? ORDER BY last_seen DESC
                """, [entity, entity]).compactMap(Self.link)
        }) ?? []
    }

    private func names(_ ids: [String]) -> [String] {
        let all = entities()
        return ids.map { id in all.first { $0.id == id }?.name ?? id }
    }

    // MARK: Writing

    package func replace(_ replacing: [String], with raw: String, scope: MemoryScope, person: String? = nil, project: ProjectKey? = nil,
                         source: String) -> Result<MemoryNote, MemoryError> {
        let text: String
        switch MemoryNote.clean(raw) {
        case .success(let cleaned): text = cleaned
        case .failure(let rejection): return .failure(MemoryError(message: rejection.message))
        }
        let target: Target
        switch resolve(scope, person: person, project: project) {
        case .success(let found): target = found
        case .failure(let failure): return .failure(failure)
        }
        let at = now()
        let day = MemoryNote.day(at, calendar: calendar)
        let key = MemoryNote.normalized(text)
        let old = Set(replacing.map(MemoryNote.normalized).filter { !$0.isEmpty && $0 != key })
        let outcome: Result<Written, MemoryError>
        do {
            outcome = try database.write { db -> Result<Written, MemoryError> in
                let valid = try Self.claims(db, where: "entity = ? AND invalid_at IS NULL", [target.id])
                let removed = valid.filter { !$0.pinned && old.contains(MemoryNote.normalized($0.text)) }
                // Refused before anything is written, so a refusal leaves no page, mention or claim behind.
                guard removed.count <= MemoryNote.maxForget else {
                    return .failure(MemoryError(message: "a note may replace at most \(MemoryNote.maxForget) others; \(removed.count) match"))
                }
                try Self.ensureEntity(db, target)
                try db.execute("UPDATE memory_entities SET mentions = mentions + 1 WHERE id = ?", [target.id])
                // The same fact again: its claim moves to today and gains the source, and no second copy is added. Older claims it makes
                // wrong are still invalidated.
                if let same = valid.first(where: { MemoryNote.normalized($0.text) == key }) {
                    try db.execute("UPDATE memory_claims SET date = ?, sources = ? WHERE id = ?",
                                   [day, Self.joined(Self.merged(same.sources, [source])), same.id])
                    for stale in removed {
                        try db.execute("UPDATE memory_claims SET invalid_at = ? WHERE id = ?", [at.timeIntervalSince1970, stale.id])
                    }
                    return .success(Written(claim: same.id, removed: removed, note: MemoryNote(text: same.text, date: day, source: source),
                                            target: target, bumped: true))
                }
                try db.execute("INSERT INTO memory_claims(entity, text, date, sources, invalid_at, pinned) VALUES(?, ?, ?, ?, NULL, 0)",
                               [target.id, text, day, source])
                let claim = try Self.lastID(db)
                for stale in removed {
                    try db.execute("UPDATE memory_claims SET invalid_at = ? WHERE id = ?", [at.timeIntervalSince1970, stale.id])
                }
                return .success(Written(claim: claim, removed: removed, note: MemoryNote(text: text, date: day, source: source),
                                        target: target, bumped: false))
            }
        } catch {
            return .failure(MemoryError(message: "could not save the note: \(error.localizedDescription)"))
        }
        switch outcome {
        case .failure(let failure):
            return .failure(failure)
        case .success(let written):
            if written.bumped {
                // The same fact again is not a change, but each older claim it removed is logged as a forget, so Undo can bring it back.
                for stale in written.removed {
                    index.record(at: at, file: written.target.id, section: written.target.person, action: .forgot, note: stale.note.line,
                                 previous: String(stale.id), source: source, claim: stale.id)
                    index.removeClaim(stale.id)
                }
            } else {
                let previous = written.removed.isEmpty ? nil : Self.joined(written.removed.map { String($0.id) })
                index.record(at: at, file: written.target.id, section: written.target.person, action: written.removed.isEmpty ? .added : .replaced,
                             note: written.note.line, previous: previous, source: source, claim: written.claim)
                index.indexClaim(written.claim, title: Self.title(written.target), text: written.note.text, at: at)
                written.removed.forEach { index.removeClaim($0.id) }
            }
            return .success(written.note)
        }
    }

    /// The hourly merge pass: one claim takes the place of several on one page. Every named claim must be valid and unpinned, or nothing
    /// changes. The merged claims stay in the page's history, so Undo brings them back.
    package func merge(_ entity: String, replacing ids: [Int64], with raw: String, source: String) -> Result<MemoryNote, MemoryError> {
        let text: String
        switch MemoryNote.clean(raw) {
        case .success(let cleaned): text = cleaned
        case .failure(let rejection): return .failure(MemoryError(message: rejection.message))
        }
        guard Set(ids).count >= 2, let page = entities().first(where: { $0.id == entity }) else {
            return .failure(MemoryError(message: "a merge needs a page and two or more claims"))
        }
        let at = now()
        let day = MemoryNote.day(at, calendar: calendar)
        let wanted = Set(ids)
        let outcome: Result<(claim: Int64, merged: [MemoryClaim]), MemoryError>
        do {
            outcome = try database.write { db -> Result<(claim: Int64, merged: [MemoryClaim]), MemoryError> in
                let valid = try Self.claims(db, where: "entity = ? AND invalid_at IS NULL", [entity])
                let merged = valid.filter { wanted.contains($0.id) }
                guard merged.count == wanted.count, merged.allSatisfy({ !$0.pinned }) else {
                    return .failure(MemoryError(message: "some of those claims are pinned or no longer hold"))
                }
                let sources = merged.reduce([String]()) { Self.merged($0, $1.sources) }
                try db.execute("INSERT INTO memory_claims(entity, text, date, sources, invalid_at, pinned) VALUES(?, ?, ?, ?, NULL, 0)",
                               [entity, text, day, Self.joined(sources)])
                let claim = try Self.lastID(db)
                for old in merged { try db.execute("UPDATE memory_claims SET invalid_at = ? WHERE id = ?", [at.timeIntervalSince1970, old.id]) }
                return .success((claim, merged))
            }
        } catch {
            return .failure(MemoryError(message: "could not merge the claims: \(error.localizedDescription)"))
        }
        switch outcome {
        case .failure(let failure):
            return .failure(failure)
        case .success(let written):
            let target = Target(id: entity, type: page.type, name: page.name, identifiers: page.identifiers,
                                person: page.type == .person ? page.name : nil)
            index.record(at: at, file: entity, section: target.person, action: .replaced, note: MemoryNote(text: text, date: day, source: source).line,
                         previous: Self.joined(written.merged.map { String($0.id) }), source: source, claim: written.claim)
            index.indexClaim(written.claim, title: Self.title(target), text: text, at: at)
            written.merged.forEach { index.removeClaim($0.id) }
            return .success(MemoryNote(text: text, date: day, source: source))
        }
    }

    /// Records that two entities are linked, such as a person who works on a project. Each pair and type is kept once: when it comes up
    /// again its count and last-seen time move.
    @discardableResult
    package func link(from: String, to: String, type: String, source: String) -> Bool {
        let at = now().timeIntervalSince1970
        do {
            try database.write { db in
                if let row = try db.rows("SELECT sources FROM memory_links WHERE from_entity = ? AND to_entity = ? AND type = ?",
                                         [from, to, type]).first {
                    let sources = Self.merged(Self.lines(row.first as? String), [source])
                    try db.execute("UPDATE memory_links SET count = count + 1, last_seen = ?, sources = ? WHERE from_entity = ? AND to_entity = ? AND type = ?",
                                   [at, Self.joined(sources), from, to, type])
                } else {
                    try db.execute("INSERT INTO memory_links(from_entity, to_entity, type, first_seen, last_seen, count, sources) VALUES(?, ?, ?, ?, ?, 1, ?)",
                                   [from, to, type, at, at, source])
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// The pages a person's name could mean, when it matches more than one. Nil when it matches none or one, so nothing needs asking.
    package func ambiguousPeople(_ name: String) -> [String]? {
        if case .ambiguous(let ids) = EntityMatcher.match(name: name, type: .person, in: records()) { return names(ids) }
        return nil
    }

    package func forget(_ query: String, scope: MemoryScope? = nil, person: String? = nil, project: ProjectKey? = nil,
                        source: String) -> Result<[ForgottenNote], MemoryError> {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .failure(MemoryError(message: "say which note to forget")) }
        let ids: [String]
        switch pagesToSearch(scope: scope, person: person, project: project) {
        case .success(let found): ids = found
        case .failure(let failure): return .failure(failure)
        }
        let all = entities()
        let matches: [MemoryClaim] = ids.flatMap { claims(of: $0) }.filter { claim in
            words.allSatisfy(claim.text.lowercased().contains)
        }
        guard !matches.isEmpty else { return .failure(MemoryError(message: "no note matches \"\(query)\"")) }
        guard matches.count <= MemoryNote.maxForget else {
            let list = matches.prefix(10).map { "- \($0.text)" }.joined(separator: "\n")
            return .failure(MemoryError(message: "\(matches.count) notes match \"\(query)\"; nothing was removed. Be more specific:\n\(list)"))
        }
        let at = now()
        do {
            try database.write { db in
                for claim in matches {
                    try db.execute("UPDATE memory_claims SET invalid_at = ? WHERE id = ?", [at.timeIntervalSince1970, claim.id])
                }
            }
        } catch {
            return .failure(MemoryError(message: "could not forget the notes: \(error.localizedDescription)"))
        }
        return .success(matches.map { claim in
            let entity = all.first { $0.id == claim.entity }
            index.record(at: at, file: claim.entity, section: entity?.type == .person ? entity?.name : nil, action: .forgot,
                         note: claim.note.line, previous: String(claim.id), source: source, claim: claim.id)
            index.removeClaim(claim.id)
            return ForgottenNote(page: entity?.name ?? claim.entity, section: entity?.type == .person ? entity?.name : nil, note: claim.note)
        })
    }

    /// Reverses one change. A claim that changed since (replaced, pinned away, forgotten again) cannot be found in the state the change
    /// left it, so the undo is refused and the change stays.
    @discardableResult
    package func undo(_ change: MemoryChange) -> Result<Void, MemoryError> {
        guard !change.undone else { return .success(()) }
        guard let claim = change.claim else {
            return .failure(MemoryError(message: "that change was made before notes moved into ironpet's database, so it cannot be undone here"))
        }
        let changed = MemoryError(message: "that note has changed since, so it cannot be undone")
        let at = now()
        let previous = (change.previous ?? "").split(separator: "\n").compactMap { Int64($0) }
        let touched: [Int64]
        do {
            let result = try database.write { db -> Result<[Int64], MemoryError> in
                func invalidate(_ id: Int64) throws -> Bool {
                    guard let row = try Self.claim(db, id: id), row.invalidAt == nil else { return false }
                    try db.execute("UPDATE memory_claims SET invalid_at = ? WHERE id = ?", [at.timeIntervalSince1970, id])
                    return true
                }
                func restore(_ id: Int64) throws -> Bool {
                    guard let row = try Self.claim(db, id: id), row.invalidAt != nil else { return false }
                    try db.execute("UPDATE memory_claims SET invalid_at = NULL WHERE id = ?", [id])
                    return true
                }
                switch change.action {
                case .added:
                    guard try invalidate(claim) else { return .failure(changed) }
                    return .success([claim])
                case .forgot:
                    guard try restore(claim) else { return .failure(changed) }
                    return .success([claim])
                case .replaced:
                    guard try invalidate(claim) else { return .failure(changed) }
                    for id in previous {
                        guard try restore(id) else { return .failure(changed) }
                    }
                    return .success([claim] + previous)
                case .tidied, .edited:
                    return .failure(MemoryError(message: "that change was made by the earlier file editor and cannot be undone here"))
                }
            }
            switch result {
            case .failure(let failure): return .failure(failure)
            case .success(let ids): touched = ids
            }
        } catch {
            return .failure(MemoryError(message: "could not undo: \(error.localizedDescription)"))
        }
        syncIndex(touched)
        index.markUndone(change.id)
        return .success(())
    }

    /// Pins or unpins a valid claim. A pinned claim is not replaced, and a replacement is added beside it.
    @discardableResult
    package func setPinned(_ claim: Int64, _ pinned: Bool) -> Bool {
        (try? database.write { db -> Bool in
            try db.execute("UPDATE memory_claims SET pinned = ? WHERE id = ? AND invalid_at IS NULL", [pinned ? 1 : 0, claim])
            return (try db.rows("SELECT changes()").first?.first as? Int64 ?? 0) > 0
        }) ?? false
    }

    /// The change log, newest first.
    package func recentChanges(limit: Int = 20) -> [MemoryChange] { index.changes(limit: limit) }

    /// Deletes every claim, entity, link and change, and the old note files and Markdown copies that hold the same facts. Chats and
    /// meetings stay searchable.
    package func forgetEverything() {
        try? database.write { db in
            try db.execute("DELETE FROM memory_links")
            try db.execute("DELETE FROM memory_claims")
            try db.execute("DELETE FROM memory_entities")
        }
        index.clearNotes()
        for folder in [LegacyMemoryFiles.directory, Self.exportDirectory] {
            try? FileManager.default.removeItem(at: folder)
        }
        ensureMe()
    }

    /// Rebuilds the search documents of every valid claim from the database.
    package func reindex() {
        index.clearClaims()
        for entity in entities() {
            for claim in claims(of: entity.id) {
                index.indexClaim(claim.id, title: Self.title(entity), text: claim.text, at: Self.day(claim.date) ?? now())
            }
        }
    }

    // MARK: The prompt

    /// One scope's valid claims for a prompt: whole notes, newest first, within `bytes`. For people, the ones the message names come
    /// first, then the ones that have come up often enough to be named unasked.
    package func recall(_ scope: MemoryScope, project: ProjectKey?, bytes: Int, naming message: String) -> String {
        switch scope {
        case .me:
            return Self.budget(notes(of: "me"), bytes: bytes, grouped: false)
        case .project:
            guard let project else { return "" }
            return Self.budget(notes(of: Self.projectID(project)), bytes: bytes, grouped: false)
        case .people:
            return Self.budget(peopleNotes(naming: message), bytes: bytes, grouped: true)
        }
    }

    package func location(_ scope: MemoryScope, project: ProjectKey?) -> String? {
        switch scope {
        case .me: return "me"
        case .people: return "people"
        case .project: return project?.name
        }
    }

    private func notes(of entity: String) -> [(note: MemoryNote, section: String?)] {
        claims(of: entity).reversed().map { ($0.note, nil) }
    }

    private func peopleNotes(naming message: String) -> [(note: MemoryNote, section: String?)] {
        let words = Set(message.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }.map(String.init))
        let text = message.lowercased()
        let people = entities().filter { $0.type == .person }
        let named = people.filter { person in
            let lower = person.name.lowercased()
            return lower.contains(" ") ? text.contains(lower) : words.contains(lower)
        }
        let namedIDs = Set(named.map(\.id))
        // The most recently noted people come next, as many as fit; each person's claims are listed with their name as the heading.
        let rest = people.filter { !namedIDs.contains($0.id) && !$0.isStub }
            .map { (person: $0, latest: claims(of: $0.id).first?.date ?? "") }
            .sorted { $0.latest > $1.latest }
            .map(\.person)
        return (named + rest).flatMap { person in
            claims(of: person.id).reversed().map { ($0.note, person.name) }
        }
    }

    /// Newest first, as whole lines, until the next one would pass `bytes`. Grouped under `## name` headings when `grouped`, which
    /// is how people are shown. When some are left out, one more line says how many and where to find them.
    package static func budget(_ notes: [(note: MemoryNote, section: String?)], bytes: Int, grouped: Bool) -> String {
        let ordered = notes.enumerated().sorted { a, b in
            let (da, db) = (a.element.note.date ?? "", b.element.note.date ?? "")
            return da != db ? da > db : a.offset > b.offset
        }.map(\.element)
        var kept: [(note: MemoryNote, section: String?)] = [], used = 0
        for item in ordered {
            let size = item.note.line.utf8.count + 1
            if used + size > bytes { break }
            kept.append(item)
            used += size
        }
        var lines: [String]
        if grouped {
            var order: [String] = []
            var bySection: [String: [String]] = [:]
            for item in kept {
                let name = item.section ?? ""
                if bySection[name] == nil { order.append(name) }
                bySection[name, default: []].append(item.note.line)
            }
            lines = order.flatMap { ($0.isEmpty ? [] : ["## \($0)"]) + (bySection[$0] ?? []) }
        } else {
            lines = kept.map(\.note.line)
        }
        let left = notes.count - kept.count
        if left > 0 { lines.append("(\(left) older note\(left == 1 ? "" : "s") not shown; use memory_search to find them.)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Import and export

    /// Writes one page's claims from the earlier note files, once, through `MemoryMigration`. A claim with the same text as one the page
    /// already holds is skipped. Returns how many were added. Throws when the database cannot write, so the migration is not marked done.
    @discardableResult
    package func importPage(id: String, type: EntityType, name: String, identifiers: [String], mentions: Int, notes: [MemoryNote]) throws -> Int {
        let target = Target(id: id, type: type, name: name, identifiers: identifiers, person: type == .person ? name : nil)
        let day = now()
        let added = try database.write { db -> [(id: Int64, text: String)] in
            try Self.ensureEntity(db, target)
            try db.execute("UPDATE memory_entities SET mentions = max(mentions, ?) WHERE id = ?", [mentions, id])
            var known = Set(try Self.claims(db, where: "entity = ? AND invalid_at IS NULL", [id]).map { MemoryNote.normalized($0.text) })
            var result: [(id: Int64, text: String)] = []
            for note in notes where !known.contains(MemoryNote.normalized(note.text)) {
                try db.execute("INSERT INTO memory_claims(entity, text, date, sources, invalid_at, pinned) VALUES(?, ?, ?, ?, NULL, 0)",
                               [id, note.text, note.date ?? "", note.source])
                result.append((try Self.lastID(db), note.text))
                known.insert(MemoryNote.normalized(note.text))
            }
            return result
        }
        for claim in added {
            index.indexClaim(claim.id, title: Self.title(target), text: claim.text, at: day)
        }
        return added.count
    }

    /// Writes each page with valid claims as a Markdown file in `exportDirectory`: `me.md`, `people.md` and `projects/<name>-<hash>.md`. A
    /// copy for reading or for another tool; nothing reads it back, and an edit to it changes nothing in ironpet.
    package func exportMarkdown() -> Result<URL, MemoryError> {
        let folder = Self.exportDirectory
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder.appendingPathComponent("projects"), withIntermediateDirectories: true)
            var written: Set<String> = []
            for entity in entities() where entity.type == .me || entity.type == .person || entity.type == .project {
                let valid = claims(of: entity.id).reversed()
                guard !valid.isEmpty || entity.type == .me else { continue }
                let lines = valid.map { $0.note.line }
                switch entity.type {
                case .me:
                    try Self.write("# About me\n\n" + Self.body(lines), to: folder.appendingPathComponent("me.md"))
                    written.insert("me.md")
                case .person:
                    continue
                case .project:
                    let key = String(entity.id.dropFirst("project:".count))
                    let name = "projects/" + Self.fileName(entity.name, key: key)
                    let header = key.hasPrefix("/") ? "Workspace: \(key)" : "Repo: \(key)"
                    try Self.write("# \(entity.name)\n\n\(header)\n\n" + Self.body(lines), to: folder.appendingPathComponent(name))
                    written.insert(name)
                default:
                    continue
                }
            }
            let people = entities().filter { $0.type == .person && !claims(of: $0.id).isEmpty }
            let peopleFile = folder.appendingPathComponent("people.md")
            if !people.isEmpty {
                let sections = people.map { person in "## \(person.name)\n\n" + Self.body(claims(of: person.id).reversed().map { $0.note.line }) }
                try Self.write("# People\n\n" + sections.joined(separator: "\n"), to: peopleFile)
            } else {
                try? files.removeItem(at: peopleFile)
            }
            // A project with nothing left, or one that is gone, must not keep its forgotten notes in the copy.
            let projectFolder = folder.appendingPathComponent("projects")
            for url in (try? files.contentsOfDirectory(at: projectFolder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "md" {
                if !written.contains("projects/" + url.lastPathComponent) { try? files.removeItem(at: url) }
            }
            return .success(folder)
        } catch {
            return .failure(MemoryError(message: "could not export the notes to \(folder.path): \(error.localizedDescription)"))
        }
    }

    // MARK: Helpers

    private func ensureMe() {
        try? database.write { db in
            try db.execute("INSERT OR IGNORE INTO memory_entities(id, type, name, aliases, identifiers, mentions) VALUES('me', 'me', 'About me', 'me\nabout me', '', 0)")
        }
    }

    /// The pages a forget looks at: the named person's, or for a scope, its pages.
    private func pagesToSearch(scope: MemoryScope?, person: String?, project: ProjectKey?) -> Result<[String], MemoryError> {
        if let name = MemoryNote.personName(person) {
            switch EntityMatcher.match(name: name, type: .person, in: records()) {
            case .found(let id): return .success([id])
            case .none: return .failure(MemoryError(message: "no note matches \"\(name)\""))
            case .ambiguous(let ids): return .failure(MemoryError(message: "more than one person matches \(name): \(names(ids).joined(separator: ", "))"))
            }
        }
        let people = entities().filter { $0.type == .person }.map(\.id)
        let projectPage = project.map(Self.projectID).map { [$0] } ?? []
        switch scope {
        case nil: return .success(["me"] + people + projectPage)
        case .me?: return .success(["me"])
        case .people?: return .success(people)
        case .project?: return .success(projectPage)
        }
    }

    private func resolve(_ scope: MemoryScope, person: String?, project: ProjectKey?) -> Result<Target, MemoryError> {
        switch scope {
        case .me:
            return .success(Target(id: "me", type: .me, name: "About me", identifiers: [], person: nil))
        case .people:
            guard let name = MemoryNote.personName(person) else { return .failure(MemoryError(message: "a note about a person needs the person's name")) }
            switch EntityMatcher.match(name: name, type: .person, in: records()) {
            case .found(let id):
                let existing = entities().first { $0.id == id }
                return .success(Target(id: id, type: .person, name: existing?.name ?? name, identifiers: [], person: existing?.name ?? name))
            case .none:
                return .success(Target(id: EntityMatcher.personID(name), type: .person, name: name, identifiers: [], person: name))
            case .ambiguous(let ids):
                return .failure(MemoryError(message: "more than one person matches \(name): \(names(ids).joined(separator: ", ")). Say which."))
            }
        case .project:
            guard let project else { return .failure(MemoryError(message: "there is no project folder to keep a project note for")) }
            return .success(Target(id: Self.projectID(project), type: .project, name: project.name, identifiers: [project.key], person: nil))
        }
    }

    private static func projectID(_ project: ProjectKey) -> String { "project:" + project.key }

    private static func title(_ target: Target) -> String {
        switch target.type {
        case .me: return "About me"
        case .person: return "Person · \(target.name)"
        case .project: return "Project · \(target.name)"
        case .org, .tool, .topic: return "\(target.type.rawValue.capitalized) · \(target.name)"
        }
    }

    private static func title(_ entity: MemoryEntity) -> String {
        title(Target(id: entity.id, type: entity.type, name: entity.name, identifiers: entity.identifiers, person: nil))
    }

    /// Brings the search documents of these claims in line with the database: a valid claim is indexed, an invalid one removed.
    private func syncIndex(_ ids: [Int64]) {
        let rows = (try? database.read { db in try ids.compactMap { try Self.claim(db, id: $0) } }) ?? []
        let entities = self.entities()
        for claim in rows {
            guard claim.invalidAt == nil, let entity = entities.first(where: { $0.id == claim.entity }) else {
                index.removeClaim(claim.id)
                continue
            }
            index.indexClaim(claim.id, title: Self.title(entity), text: claim.text, at: Self.day(claim.date) ?? now())
        }
    }

    private static func ensureEntity(_ db: Database.Connection, _ target: Target) throws {
        try db.execute("INSERT OR IGNORE INTO memory_entities(id, type, name, aliases, identifiers, mentions) VALUES(?, ?, ?, '', '', 0)",
                       [target.id, target.type.rawValue, target.name])
        guard !target.identifiers.isEmpty else { return }
        let current = (try db.rows("SELECT identifiers FROM memory_entities WHERE id = ?", [target.id]).first?.first as? String) ?? ""
        let merged = merged(current.isEmpty ? [] : current.components(separatedBy: "\n"), target.identifiers)
        try db.execute("UPDATE memory_entities SET identifiers = ? WHERE id = ?", [joined(merged), target.id])
    }

    private static func entityRows(_ db: Database.Connection) throws -> [MemoryEntity] {
        try db.rows("SELECT id, type, name, aliases, identifiers, mentions FROM memory_entities").compactMap { row in
            guard let id = row[0] as? String, let type = (row[1] as? String).flatMap(EntityType.init(rawValue:)),
                  let name = row[2] as? String else { return nil }
            return MemoryEntity(id: id, type: type, name: name, aliases: lines(row[3] as? String), identifiers: lines(row[4] as? String),
                                mentions: Int(row[5] as? Int64 ?? 0))
        }
    }

    nonisolated private static func claims(_ db: Database.Connection, where condition: String, order: String = "date DESC, id DESC",
                                           _ args: [Database.Value]) throws -> [MemoryClaim] {
        try db.rows("SELECT id, entity, text, date, sources, invalid_at, pinned FROM memory_claims WHERE \(condition) ORDER BY \(order)",
                    args).compactMap(claim)
    }

    nonisolated private static func claim(_ db: Database.Connection, id: Int64) throws -> MemoryClaim? {
        try db.rows("SELECT id, entity, text, date, sources, invalid_at, pinned FROM memory_claims WHERE id = ?", [id]).first.flatMap(claim)
    }

    nonisolated private static func claim(_ row: [Database.Value]) -> MemoryClaim? {
        guard let id = row[0] as? Int64, let entity = row[1] as? String, let text = row[2] as? String else { return nil }
        return MemoryClaim(id: id, entity: entity, text: text, date: row[3] as? String ?? "", sources: lines(row[4] as? String),
                           invalidAt: (row[5] as? Double).map(Date.init(timeIntervalSince1970:)), pinned: (row[6] as? Int64 ?? 0) != 0)
    }

    nonisolated private static func link(_ row: [Database.Value]) -> MemoryLink? {
        guard let type = row[0] as? String, let from = row[1] as? String, let to = row[2] as? String else { return nil }
        return MemoryLink(type: type, from: from, to: to, count: Int(row[3] as? Int64 ?? 0),
                          firstSeen: Date(timeIntervalSince1970: row[4] as? Double ?? 0),
                          lastSeen: Date(timeIntervalSince1970: row[5] as? Double ?? 0), sources: lines(row[6] as? String))
    }

    private static func lastID(_ db: Database.Connection) throws -> Int64 {
        (try db.rows("SELECT last_insert_rowid()").first?.first as? Int64) ?? 0
    }

    nonisolated private static func lines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n").map(String.init)
    }

    private static func joined(_ values: [String]) -> String { values.joined(separator: "\n") }

    private static func merged(_ existing: [String], _ more: [String]) -> [String] {
        existing + more.filter { !existing.contains($0) }
    }

    private static func day(_ text: String) -> Date? {
        guard MemoryNote.isDay(text) else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func body(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `<name>-<8 hex>.md`, the name made of letters and digits, so a file name is safe and stable for the same key.
    private static func fileName(_ name: String, key: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(slug)-\(digest).md"
    }
}

private extension EntityType {
    /// Where a type sits in a list: the user, then people, projects and the rest.
    var sortRank: Int {
        switch self {
        case .me: return 0
        case .person: return 1
        case .project: return 2
        case .org, .tool, .topic: return 3
        }
    }
}
