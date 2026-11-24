import Foundation

/// Ghost's memory: notes about the user, their projects and people, and search over past chats, meetings and the screen. The
/// `memory_*` tools reach it here, and so do Settings → Memory and the chat's Memory folder button. The app owner supplies the
/// services, which exist only once memory is set up.
@MainActor
package final class MemoryAPI {
    /// The running app's memory, for the views that show it. `IronPetAPI` sets it to its own.
    package static var live: MemoryAPI?

    private let services: () -> MemoryMCP.Services?
    private let pages: () -> EntityMemoryStore

    /// `pages` names the store the Settings pages read. It defaults to the app's shared one.
    package init(services: @escaping () -> MemoryMCP.Services?, pages: (() -> EntityMemoryStore)? = nil) {
        self.services = services
        self.pages = pages ?? { EntityMemoryStore.shared }
    }

    package func handles(_ name: String) -> Bool { MemoryMCP.names.contains(name) }

    /// Runs one `memory_*` tool. `caller` names a session that is not the user's chat, such as `automation:<id>`.
    package func callTool(_ name: String, _ args: [String: Any], caller: String? = nil) -> Result<Any, MemoryMCP.Failure> {
        guard let services = services() else {
            return .failure(MemoryMCP.Failure(message: "Ghost's memory is not available right now"))
        }
        return MemoryMCP.call(name, args, services: services, caller: caller)
    }

    // MARK: Pages, for Settings → Memory

    package func entities() -> [MemoryEntity] { pages().entities() }

    package func claims(of entity: String) -> [MemoryClaim] { pages().claims(of: entity) }

    /// The claims the page used to hold, newest first.
    package func history(of entity: String) -> [MemoryClaim] { pages().history(of: entity) }

    /// The change log, newest first.
    package func recentChanges(limit: Int = 20) -> [MemoryChange] { pages().recentChanges(limit: limit) }

    package func search(_ query: String, limit: Int = 20) -> [MemoryIndex.Hit] { pages().index.search(query, limit: limit) }

    /// Pins or unpins a claim. Returns false when the claim is no longer valid.
    package func setPinned(_ claim: Int64, _ pinned: Bool) -> Bool { pages().setPinned(claim, pinned) }

    /// Puts a change back. Refuses when the page has changed since.
    package func undo(_ change: MemoryChange) -> Result<Void, MemoryError> { pages().undo(change) }

    /// Deletes every claim, the old note files and the Markdown copies. Chats and meetings stay searchable.
    package func forgetEverything() { pages().forgetEverything() }

    /// Writes the Markdown copy of every page, and returns the folder.
    package func exportMarkdown() -> Result<URL, MemoryError> { pages().exportMarkdown() }
}
