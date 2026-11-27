import Foundation

/// The cleanup the user runs when memory has drifted: it proposes moving notes to the page they are about, merging pages that name
/// one thing, creating organization pages, and deleting pages that are empty or are work items. It can run any number of times. It
/// changes nothing by itself: `apply` runs one proposal the user approved, and `skip` records one they refused so later runs do not
/// offer it again. Moves are logged in `memory_changes`, so Undo puts a note back; a merge keeps every earlier version of the facts.
///
/// Deterministic checks find the merges and deletions. A model, when one is available, also places notes (`Classifier`). Without one the
/// cleanup still runs and offers what the checks find.
@MainActor
package enum MemoryCleanup {
    /// The source on the change rows the cleanup writes.
    package static let source = "cleanup"
    /// Most notes one run shows the model, in batches of `MemoryResort.batchSize`.
    package static let maxNotes = 150
    private static let skipPrefix = "cleanup:skip:"

    /// One thing the cleanup would do.
    package struct Proposal: Equatable, Identifiable {
        package enum Action: Equatable {
            /// Moves notes on a page to another page, which is made when it does not exist.
            case move(claims: [Int64], scope: MemoryScope, entity: String)
            /// Files notes that waited for a page, as `EntityMemoryStore.park` kept them.
            case file(notes: [Int64], scope: MemoryScope, entity: String)
            /// Merges pages of one type into `into`. Page ids.
            case merge(pages: [String], into: String)
            /// Deletes a page.
            case delete(page: String)
            /// Merges near-duplicate notes on one page into one note with `text`. The merged notes stay in the page's history.
            case mergeNotes(page: String, claims: [Int64], text: String)
        }

        /// Stable across runs, so a skipped proposal is recognised again.
        package let id: String
        package let title: String
        package let detail: String
        package let action: Action
        /// True when applying makes a page that does not exist yet.
        package let createsPage: Bool
    }

    /// One note the model places: on a page now, or waiting.
    package struct Note: Equatable {
        package let ref: String
        package let text: String
        /// The page it is on, or "waiting" for an unsorted note.
        package let page: String
        package let pageID: String?
        package let claim: Int64?
        package let unsorted: Int64?
    }

    /// What the model said.
    package struct Answer: Equatable {
        package init(moves: [MemoryResort.Classification], merges: [MergeSuggestion] = []) {
            self.moves = moves
            self.merges = merges
        }

        package var moves: [MemoryResort.Classification]
        package var merges: [MergeSuggestion]
    }

    /// Pages the model says name one thing. Names of pages that exist.
    package struct MergeSuggestion: Equatable {
        package init(keep: String, others: [String]) {
            self.keep = keep
            self.others = others
        }

        package let keep: String
        package let others: [String]
    }

    /// Asks the model about a batch of notes and the pages that exist. Nil when it could not answer.
    package typealias Classifier = @MainActor (_ batch: [Note], _ pages: [MemoryEntity]) async -> Answer?

    package struct Run: Equatable {
        package var proposals: [Proposal]
        /// True when the model could not answer, so the proposals are only what the checks found.
        package var modelFailed: Bool
    }

    // MARK: Proposing

    /// Runs the cleanup: what the checks find, plus the model's answer for each batch of notes. Nothing is changed.
    package static func propose(in store: EntityMemoryStore, classify: Classifier? = nil) async -> Run {
        var proposals = mergeProposals(in: store) + deleteProposals(in: store) + duplicateNoteProposals(in: store)
        var failed = false
        if let classify {
            let entities = store.entities()
            let notes = candidates(in: store, entities: entities)
            var answers = Answer(moves: [])
            for start in stride(from: 0, to: notes.count, by: MemoryResort.batchSize) {
                let batch = Array(notes[start..<min(start + MemoryResort.batchSize, notes.count)])
                guard let answer = await classify(batch, entities) else {
                    failed = true
                    break
                }
                answers.moves += answer.moves
                answers.merges += answer.merges
            }
            proposals += moveProposals(answers.moves, notes: notes, in: store, entities: entities)
            proposals += suggestedMerges(answers.merges, existing: proposals, in: store, entities: entities)
        }
        return Run(proposals: unseen(proposals, in: store), modelFailed: failed)
    }

    /// The notes the model places: every unpinned note on the user's page and on a project page, and the notes that wait.
    package static func candidates(in store: EntityMemoryStore, entities: [MemoryEntity]? = nil) -> [Note] {
        let all = entities ?? store.entities()
        var notes: [Note] = store.unsorted().map {
            Note(ref: "unsorted_\($0.id)", text: $0.text, page: "waiting" + ($0.folder.isEmpty ? "" : " (chat in \($0.folder))"), pageID: nil,
                 claim: nil, unsorted: $0.id)
        }
        for page in all where page.type == .project || page.type == .me {
            for claim in store.claims(of: page.id).filter({ !$0.pinned }).reversed() {
                notes.append(Note(ref: claim.ref, text: claim.text, page: page.name, pageID: page.id, claim: claim.id, unsorted: nil))
            }
        }
        return Array(notes.prefix(maxNotes))
    }

    /// Groups the model's moves by the page the notes leave and the page they go to, one proposal for each group.
    private static func moveProposals(_ moves: [MemoryResort.Classification], notes: [Note], in store: EntityMemoryStore,
                                      entities: [MemoryEntity]) -> [Proposal] {
        let byRef = Dictionary(notes.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        struct Group { var claims: [Int64] = []; var unsorted: [Int64] = []; var scope: MemoryScope; var entity: String; var from: String; var creates: Bool }
        var groups: [String: Group] = [:]
        var order: [String] = []
        for move in moves {
            guard let note = byRef[move.ref], let type = move.scope.namedType, !WorkItemGuard.isWorkItem(move.entity),
                  let name = MemoryNote.personName(move.entity) else { continue }
            let target = target(type, name, in: entities)
            if let id = target.id, id == note.pageID { continue }
            let from = note.pageID ?? "waiting"
            let key = "\(from)>\(target.id ?? type.rawValue + ":" + EntityMatcher.normalize(name))"
            if groups[key] == nil {
                groups[key] = Group(scope: move.scope, entity: target.name ?? name, from: note.page, creates: target.id == nil)
                order.append(key)
            }
            if let claim = note.claim { groups[key]?.claims.append(claim) }
            if let unsorted = note.unsorted { groups[key]?.unsorted.append(unsorted) }
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            let count = group.claims.count + group.unsorted.count
            let noun = count == 1 ? "note" : "notes"
            let place = "\(label(group.scope).lowercased()) page \(group.entity)"
            let title = group.creates ? "Create the \(place) and move \(count) \(noun) to it" : "Move \(count) \(noun) to \(group.entity)"
            // A group is one source, so it holds claims or waiting notes, never both.
            let action: Proposal.Action = group.claims.isEmpty
                ? .file(notes: group.unsorted, scope: group.scope, entity: group.entity)
                : .move(claims: group.claims, scope: group.scope, entity: group.entity)
            return Proposal(id: "move:" + key, title: title, detail: "From \(group.from).", action: action, createsPage: group.creates)
        }
    }

    private static func label(_ scope: MemoryScope) -> String { (scope.namedType ?? .project).label }

    /// The page a name finds among the pages of that type, or nothing when a new page would be made.
    private static func target(_ type: EntityType, _ name: String, in entities: [MemoryEntity]) -> (id: String?, name: String?) {
        let records = entities.map(\.record)
        if case .found(let id) = EntityMatcher.match(name: name, identifiers: [name], type: type, in: records),
           let page = entities.first(where: { $0.id == id }) { return (page.id, page.name) }
        return (nil, nil)
    }

    /// Pages of one type whose names are variants of each other, merged into the one with the most facts.
    private static func mergeProposals(in store: EntityMemoryStore) -> [Proposal] {
        let pages = store.entities().filter { $0.type != .me }
        let facts = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, store.claims(of: $0.id).count) })
        // Pages with no fact and no link are the delete check's business unless a variant of their name exists.
        var parent = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.id) })
        func root(_ id: String) -> String {
            var id = id
            while let up = parent[id], up != id { id = up }
            return id
        }
        for (index, a) in pages.enumerated() {
            for b in pages[(index + 1)...] where a.type == b.type && EntityMatcher.mayBeSame(a.record, b.record) {
                parent[root(a.id)] = root(b.id)
            }
        }
        let groups = Dictionary(grouping: pages, by: { root($0.id) }).values.filter { $0.count >= 2 }
        return groups.map { group in
            let keep = group.max { (facts[$0.id] ?? 0, $0.name.count) < (facts[$1.id] ?? 0, $1.name.count) } ?? group[0]
            let others = group.filter { $0.id != keep.id }
            return mergeProposal(keep: keep, others: others, facts: facts)
        }.sorted { $0.id < $1.id }
    }

    private static func mergeProposal(keep: MemoryEntity, others: [MemoryEntity], facts: [String: Int]) -> Proposal {
        let names = others.map { "\($0.name) (\(facts[$0.id] ?? 0))" }.joined(separator: ", ")
        let ids = ([keep] + others).map(\.id).sorted()
        return Proposal(id: "merge:" + ids.joined(separator: "+"), title: "Merge \(others.count + 1) pages into \(keep.name)",
                        detail: "Merges \(names). Their names become aliases of \(keep.name).",
                        action: .merge(pages: others.map(\.id), into: keep.id), createsPage: false)
    }

    private static func suggestedMerges(_ merges: [MergeSuggestion], existing: [Proposal], in store: EntityMemoryStore,
                                        entities: [MemoryEntity]) -> [Proposal] {
        let facts = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, store.claims(of: $0.id).count) })
        let covered = Set(existing.compactMap { proposal -> [String]? in
            if case .merge(let pages, let into) = proposal.action { return pages + [into] }
            return nil
        }.flatMap { $0 })
        var seen = covered
        return merges.compactMap { suggestion in
            func find(_ name: String) -> MemoryEntity? {
                guard case .found(let id) = EntityMatcher.match(name: name, identifiers: [name], in: entities.filter { $0.type != .me }.map(\.record)) else { return nil }
                return entities.first { $0.id == id }
            }
            guard let keep = find(suggestion.keep), !seen.contains(keep.id) else { return nil }
            var others: [MemoryEntity] = []
            for name in suggestion.others {
                if let page = find(name), page.id != keep.id, page.type == keep.type, !seen.contains(page.id), !others.contains(where: { $0.id == page.id }) {
                    others.append(page)
                }
            }
            guard !others.isEmpty else { return nil }
            seen.insert(keep.id)
            others.forEach { seen.insert($0.id) }
            return mergeProposal(keep: keep, others: others, facts: facts)
        }
    }

    /// Notes on one page that say the same fact in other words (`NearDuplicate`), one proposal for each group. The merged note keeps the
    /// longest wording, the merged sources, and today's date. Pinned notes are left out.
    private static func duplicateNoteProposals(in store: EntityMemoryStore) -> [Proposal] {
        var proposals: [Proposal] = []
        for page in store.entities() {
            let claims = store.claims(of: page.id).filter { !$0.pinned }
            for group in NearDuplicate.groups(claims.map(\.text)) {
                let members = group.map { claims[$0] }
                guard let longest = members.max(by: { $0.text.count < $1.text.count }) else { continue }
                let ids = members.map(\.id).sorted()
                proposals.append(Proposal(id: "notes:\(page.id):" + ids.map(String.init).joined(separator: "+"),
                                          title: "Merge \(members.count) similar notes on \(page.name)",
                                          detail: "They say the same thing in different words. Keeps \"\(longest.text)\".",
                                          action: .mergeNotes(page: page.id, claims: ids, text: longest.text), createsPage: false))
            }
        }
        return proposals
    }

    /// Pages to delete: a work item that holds facts or none, and a page with no fact, no link, no mention and no history. An empty page
    /// whose name is a variant of another page is a merge instead (`mergeProposals`).
    private static func deleteProposals(in store: EntityMemoryStore) -> [Proposal] {
        let pages = store.entities().filter { $0.type != .me }
        var proposals: [Proposal] = []
        for page in pages {
            let facts = store.claims(of: page.id).count
            let workItem = WorkItemGuard.isWorkItem(page.name)
            let empty = facts == 0
            guard empty || workItem else { continue }
            if empty, !workItem {
                // A person's page with no fact is a stub that records a mention. Only a page nothing refers to is a mistake.
                guard page.type != .person, page.sources.isEmpty, store.history(of: page.id).isEmpty,
                      store.detail(page.id)?.linkGroups.isEmpty ?? true else { continue }
                // A variant of another page is offered as a merge.
                if pages.contains(where: { $0.id != page.id && $0.type == page.type && EntityMatcher.mayBeSame(page.record, $0.record) }) { continue }
            } else if empty {
                guard store.history(of: page.id).isEmpty else { continue }
            }
            let why = workItem ? "\(page.name) is a ticket, issue or PR, not a page." : "\(page.name) has no notes and nothing refers to it."
            proposals.append(Proposal(id: "delete:" + page.id, title: "Delete the page \(page.name)",
                                      detail: why + (facts > 0 ? " Its \(facts) note\(facts == 1 ? "" : "s") are forgotten and stay in the change log." : ""),
                                      action: .delete(page: page.id), createsPage: false))
        }
        return proposals
    }

    // MARK: Skipping and applying

    /// Drops the proposals the user skipped before.
    private static func unseen(_ proposals: [Proposal], in store: EntityMemoryStore) -> [Proposal] {
        proposals.filter { !isSkipped($0, in: store) }
    }

    package static func isSkipped(_ proposal: Proposal, in store: EntityMemoryStore) -> Bool {
        store.index.cursor(skipPrefix + proposal.id) != nil
    }

    /// Records that the user refused this proposal, so a later run does not offer it again.
    package static func skip(_ proposal: Proposal, in store: EntityMemoryStore) {
        store.index.setCursor(skipPrefix + proposal.id, item: "1", at: store.now())
    }

    /// Does what the user approved, and says what happened. A proposal that no longer fits (a note already moved, a page already gone)
    /// does nothing and says so.
    package static func apply(_ proposal: Proposal, in store: EntityMemoryStore) -> Result<String, MemoryError> {
        switch proposal.action {
        case .move(let claims, let scope, let entity):
            let moved = store.move(claims.map { EntityMemoryStore.Move(claim: $0, scope: scope, entity: entity) }, source: source)
            return moved > 0 ? .success("Moved \(moved) note\(moved == 1 ? "" : "s") to \(entity).")
                             : .failure(MemoryError(message: "Those notes are no longer on that page."))
        case .file(let notes, let scope, let entity):
            let filed = notes.filter { store.file(unsorted: $0, scope: scope, entity: entity, source: source) }.count
            return filed > 0 ? .success("Filed \(filed) note\(filed == 1 ? "" : "s") on \(entity).")
                             : .failure(MemoryError(message: "Those notes are no longer waiting."))
        case .merge(let pages, let into):
            switch store.mergePages(pages, into: into) {
            case .success(let merged): return .success("Merged \(merged.merged.count) page\(merged.merged.count == 1 ? "" : "s") into \(merged.kept.name).")
            case .failure(let failure): return .failure(failure)
            }
        case .mergeNotes(let page, let claims, let text):
            switch store.merge(page, replacing: claims, with: text, source: source) {
            case .success: return .success("Merged \(claims.count) notes into one.")
            case .failure(let failure): return .failure(failure)
            }
        case .delete(let page):
            return store.deletePage(page, source: source) ? .success("Deleted the page.") : .failure(MemoryError(message: "That page is already gone."))
        }
    }

    // MARK: Reading the model's answer

    /// The moves and merges in an answer. Nil when it is not the cleanup object. An entry without the fields it needs is skipped.
    package static func parse(_ answer: String) -> Answer? {
        guard let object = ReflectionReading.jsonObject(in: answer), object["moves"] != nil || object["merges"] != nil else { return nil }
        let moves = MemoryResort.parse(answer) ?? []
        let merges = (object["merges"] as? [Any] ?? []).compactMap { raw -> MergeSuggestion? in
            guard let entry = raw as? [String: Any], let keep = entry["keep"] as? String,
                  let others = (entry["others"] as? [Any])?.compactMap({ $0 as? String }), !others.isEmpty else { return nil }
            return MergeSuggestion(keep: keep, others: others)
        }
        return Answer(moves: moves, merges: merges)
    }
}
