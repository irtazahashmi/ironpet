import Foundation
import IronPetKit
#if canImport(Combine)
import Combine
#endif

/// An item an agent adds to the inbox.
package struct SuggestTaskRequest: Codable, Equatable {
    package init(draft: TaskSuggestion.Draft, kind: TaskSource, sourceRef: String) {
        self.draft = draft
        self.kind = kind
        self.sourceRef = sourceRef
    }

    package var draft: TaskSuggestion.Draft
    package var kind: TaskSource
    package var sourceRef: String
}

/// Takes an inbox item off the list because it is wrong or a duplicate.
package struct RemoveSuggestionRequest: Codable, Equatable {
    package init(id: String, note: String? = nil) {
        self.id = id
        self.note = note
    }

    package var id: String
    package var note: String?
}

/// The inbox: items waiting for the user to mark them done or remove them. The one way a client reads or changes them.
///
/// This is an `ObservableObject` on Apple platforms, so a SwiftUI view can redraw when the list changes. The list itself is read through the
/// properties and calls below, never from the store.
@MainActor
package final class TasksAPI {
    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    private let store: TaskStore
    private var forwarding: [ChangeToken] = []

    package init(store: TaskStore) {
        self.store = store
        forwarding = [
            store.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    /// The public id of a record kept in the same database, created on first use.
    package func ref(_ kind: RecordKind, _ key: String) -> String? { store.records.ref(kind, key) }

    /// Why the inbox is only in memory, when the database could not be opened.
    package var unavailable: String? { store.unavailable }

    /// Every item, oldest first.
    package var suggestions: [TaskSuggestion] { store.suggestions }

    /// The item that was added, or none when it was a repeat or the title is already in the inbox.
    @discardableResult
    package func suggest(_ request: SuggestTaskRequest) -> [TaskSuggestion] {
        store.suggest(request.draft, agent: request.kind, sourceRef: request.sourceRef)
    }

    /// Takes the item off the list. Nothing else is created.
    package func done(_ id: String) throws {
        try run { try store.done(id) }
    }

    /// Takes a wrong or duplicate item off the list.
    package func remove(_ request: RemoveSuggestionRequest) throws {
        try run { try store.remove(request.id, note: request.note) }
    }

    // MARK: Errors

    private func run<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TaskError {
            throw error.message.hasPrefix("no inbox item") ? APIError.notFound(error.message) : APIError.invalid(error.message)
        } catch {
            throw APIError.wrap(error)
        }
    }
}

#if canImport(Combine)

extension TasksAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
