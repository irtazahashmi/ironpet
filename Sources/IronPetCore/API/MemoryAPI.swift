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

    // MARK: Pages, for the Memory section and the phone

    /// Every page that has a fact, newest update first.
    package func browseRows() -> [MemoryRow] { pages().browseRows() }

    /// The list for a filter and a search, with the same rule on the Mac and the phone.
    package func list(filter: MemoryFilter, query: String) -> MemoryList { MemoryBrowser.list(browseRows(), filter: filter, query: query) }

    /// One page in full, by id or `page_` ref.
    package func detail(_ page: String) -> MemoryDetail? { pages().detail(page) }

    /// The valid fact with this `claim_` ref.
    package func claim(ref: String) -> MemoryClaim? { pages().claim(ref: ref) }

    /// Forgets one fact. The change log keeps it, but no screen offers Undo.
    @discardableResult
    package func forgetClaim(_ id: Int64) -> Bool { pages().forgetClaim(id, source: MemoryNote.userSource) }

    /// Forgets every fact of a page and its links.
    @discardableResult
    package func forgetPage(_ page: String) -> Bool { pages().forgetPage(page, source: MemoryNote.userSource) }

    /// Merges pages of one type into `keep` (ids, `page_` refs or names). Moves their facts and links, keeps their names as aliases and
    /// deletes them. This cannot be undone.
    package func mergePages(_ others: [String], into keep: String) -> Result<EntityMemoryStore.PageMerge, MemoryError> {
        pages().mergePages(others, into: keep)
    }

    /// Puts a change back. Refuses when the page has changed since.
    package func undo(_ change: MemoryChange) -> Result<Void, MemoryError> { pages().undo(change) }

    /// Deletes every claim, the old note files and the Markdown copies. Chats and meetings stay searchable.
    package func forgetEverything() { pages().forgetEverything() }

    /// Writes the Markdown copy of every page, and returns the folder.
    package func exportMarkdown() -> Result<URL, MemoryError> { pages().exportMarkdown() }
}
