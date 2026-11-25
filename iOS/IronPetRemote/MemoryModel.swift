import Foundation
import IronPetKit
import Observation

/// The Memory screen: the list for a chip and a search, and the pages opened from it. The Mac decides what matches (the same rule as its
/// own Memory section), so the phone sends the chip and the text and shows what comes back.
@MainActor @Observable
final class MemoryModel: SocketModel {
    var filter: RemoteMemoryFilter = .all
    /// What the search field holds. The view reloads 250 ms after it stops changing.
    var query = ""
    private(set) var list: RemoteMemoryList?
    /// Pages already read, by id, so Back shows a page at once.
    private(set) var pages: [String: RemoteMemoryPage] = [:]
    /// Pages that were forgotten from the phone, so an open screen can close.
    private(set) var forgottenPages: Set<String> = []

    static let debounce: Duration = .milliseconds(250)

    override func reload() async {
        let chip = filter, text = query
        if let fresh = await run({ try await self.client.memory(filter: chip, query: text) }), chip == filter, text == query { list = fresh }
    }

    /// Selecting the chip that is already selected returns to All.
    func select(_ chip: RemoteMemoryFilter) async {
        filter = (chip == filter) ? .all : chip
        await reload()
    }

    /// Reads the page again, whether or not it is cached.
    func loadPage(_ id: String) async {
        if let page = await run({ try await self.client.memoryPage(id: id) }) { pages[id] = page }
    }

    func pin(_ fact: RemoteMemoryFact, on page: String) async {
        guard await run({ try await self.client.pinMemoryFact(id: fact.id, pinned: !fact.pinned) }) != nil else { return }
        await loadPage(page)
        await reload()
    }

    func forget(_ fact: RemoteMemoryFact, on page: String) async {
        guard await run({ try await self.client.forgetMemoryFact(id: fact.id) }) != nil else { return }
        await loadPage(page)
        await reload()
    }

    func forgetPage(_ id: String) async {
        guard await run({ try await self.client.forgetMemoryPage(id: id) }) != nil else { return }
        pages[id] = nil
        forgottenPages.insert(id)
        await reload()
    }
}

extension RemoteMemoryFact {
    /// "25 Nov 2026" for a `yyyy-MM-dd` date, empty for a note without one.
    var dateText: String { MemoryDay.parse(date)?.formatted(.dateTime.day().month(.abbreviated).year()) ?? date }
}
