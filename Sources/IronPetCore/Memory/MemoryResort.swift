import Foundation

/// Moves the notes that were filed on a project page by the folder a chat ran in to the page they are about, once. A model says which
/// project, organization, topic or tool each note is about; `EntityMemoryStore.move` does the moving and logs each move in
/// `memory_changes`, so Undo puts the note back. A note keeps its text, date and sources, and nothing is deleted. A run that could not
/// classify every batch is not recorded, and the next digest tries again: a note already moved is on its page and stays there.
@MainActor
package enum MemoryResort {
    /// The reflection cursor that marks the run done.
    package static let doneKey = "memory:entities-resorted"
    /// The source on the change rows the re-sort writes.
    package static let source = "resort"
    /// Most notes one model call classifies.
    package static let batchSize = 25

    /// One note on a project page, for the model to place.
    package struct Item: Equatable {
        package let id: Int64
        package let ref: String
        package let text: String
        /// The name of the page it is on now.
        package let page: String
    }

    /// Where the model put one note.
    package struct Classification: Equatable {
        package init(ref: String, scope: MemoryScope, entity: String) {
            self.ref = ref
            self.scope = scope
            self.entity = entity
        }

        package let ref: String
        package let scope: MemoryScope
        package let entity: String
    }

    /// Classifies a batch. Nil when it could not, which stops the run without recording it.
    package typealias Classifier = @MainActor (_ batch: [Item]) async -> [Classification]?

    /// The notes the re-sort looks at: every valid, unpinned claim on a project page, oldest page first.
    package static func candidates(in store: EntityMemoryStore) -> [Item] {
        store.entities().filter { $0.type == .project }.flatMap { page in
            store.claims(of: page.id).filter { !$0.pinned }.reversed().map { Item(id: $0.id, ref: $0.ref, text: $0.text, page: page.name) }
        }
    }

    /// Whether the re-sort has run.
    package static func isDone(_ store: EntityMemoryStore) -> Bool { store.index.cursor(doneKey) != nil }

    /// Runs the re-sort if it has not run. Returns how many notes moved, or nil when a batch could not be classified.
    @discardableResult
    package static func run(into store: EntityMemoryStore, classify: Classifier) async -> Int? {
        guard !isDone(store) else { return 0 }
        let items = candidates(in: store)
        var moved = 0
        for start in stride(from: 0, to: items.count, by: batchSize) {
            let batch = Array(items[start..<min(start + batchSize, items.count)])
            guard let answers = await classify(batch) else { return nil }
            let byRef = Dictionary(batch.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
            // Only a note that was shown can be moved, and only to a project, organization, topic or tool.
            let moves = answers.compactMap { answer -> EntityMemoryStore.Move? in
                guard let item = byRef[answer.ref], answer.scope.namedType != nil else { return nil }
                return EntityMemoryStore.Move(claim: item.id, scope: answer.scope, entity: answer.entity)
            }
            moved += store.move(moves, source: source)
        }
        store.index.setCursor(doneKey, item: "1")
        return moved
    }

    /// The moves an answer names. Nil when the answer is not the moves object; an entry without a known scope or a name is skipped.
    package static func parse(_ answer: String) -> [Classification]? {
        guard let moves = ReflectionReading.jsonObject(in: answer)?["moves"] as? [Any] else { return nil }
        return moves.compactMap { raw in
            guard let entry = raw as? [String: Any], let ref = entry["ref"] as? String, let entity = entry["entity"] as? String,
                  let scope = (entry["scope"] as? String).flatMap({ MemoryScope(rawValue: $0.lowercased()) }) else { return nil }
            return Classification(ref: ref, scope: scope, entity: entity)
        }
    }
}
