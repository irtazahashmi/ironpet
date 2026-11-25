import Foundation

/// A note `forget` removed, and the page it was on.
package struct ForgottenNote: Equatable {
    package init(page: String, section: String?, note: MemoryNote) {
        self.page = page
        self.section = section
        self.note = note
    }

    /// The entity's name, such as "About me" or "ironpet".
    package let page: String
    /// The person, for a note about someone.
    package let section: String?
    package let note: MemoryNote
}

package struct MemoryError: Error, Equatable, LocalizedError {
    package init(message: String) {
        self.message = message
    }

    package let message: String
    package var errorDescription: String? { message }
}

/// Ghost's notes as the memory tools, the chat preamble and the learning pass see them. `EntityMemoryStore` keeps them as dated claims
/// on entity pages in `ironpet.db`; another store can replace it without those callers changing.
@MainActor
package protocol MemoryStore: AnyObject {
    /// Saves a claim in place of older ones it makes wrong (`replacing` names them by text; none for a plain save). A claim that is
    /// already there comes back instead of being added twice. Refuses secrets, and replacing more than `MemoryNote.maxForget` claims.
    /// `entity` names the project, organization, topic or tool a note is about. A `project` note without it goes on the chat's `project`.
    func replace(_ replacing: [String], with text: String, scope: MemoryScope, person: String?, project: ProjectKey?, entity: String?,
                 source: String) -> Result<MemoryNote, MemoryError>
    /// Removes the claims that contain every word of `query`. They stay in the page's history, so Undo brings them back. Refuses when
    /// nothing matches or more than `MemoryNote.maxForget` do.
    func forget(_ query: String, scope: MemoryScope?, person: String?, project: ProjectKey?, entity: String?, source: String) -> Result<[ForgottenNote], MemoryError>
    /// One scope's valid claims for a prompt: whole notes, newest first, within `bytes`, and a line saying how many were left out. For
    /// people, those `message` names come first. Empty when there are none.
    func recall(_ scope: MemoryScope, project: ProjectKey?, bytes: Int, naming message: String) -> String
    /// The page a scope's notes are on, for the prompt (`me`, `people`, or the project's name). Nil when there is no such page.
    func location(_ scope: MemoryScope, project: ProjectKey?, entity: String?) -> String?
    /// An entity's page, found by name, alias or identifier. Ambiguous or unknown names are refused, not guessed.
    func page(_ name: String) -> Result<EntityPage, MemoryError>
    /// An entity's links, in either direction, optionally of one type.
    func links(_ name: String, type: String?) -> Result<[MemoryLink], MemoryError>
}

extension MemoryStore {
    @discardableResult
    package func remember(_ text: String, scope: MemoryScope, person: String? = nil, project: ProjectKey? = nil, entity: String? = nil,
                          source: String) -> Result<MemoryNote, MemoryError> {
        replace([], with: text, scope: scope, person: person, project: project, entity: entity, source: source)
    }
}

/// The markdown note files of earlier builds, in `~/.ironpet/memory`. Nothing writes them any more: `MemoryMigration` reads them once,
/// and the rest of the app only asks whether a path is inside that folder, so an agent cannot edit them.
package enum LegacyMemoryFiles {
    /// A variable so tests can point it at a temp folder. Set at launch or in a test's setUp, before any store reads it.
    package nonisolated(unsafe) static var directory = Paths.root.appendingPathComponent("memory")

    /// Whether a path is inside the old memory folder, so an automation's session may not edit it.
    package nonisolated static func contains(_ path: String) -> Bool {
        comparable(path).hasPrefix(comparable(directory.path) + "/")
    }

    /// Resolved and lowercased, since the Mac's file system ignores case: `~/.IRONPET/Memory/me.md` is the same file.
    nonisolated private static func comparable(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }
}
