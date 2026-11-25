import Foundation
import IronPetKit

/// The Memory routes, as calls on `IronPetAPI.memory`. Facts about the user and the people around them leave the Mac here (SECURITY.md,
/// "Memory"). The phone can browse, search, pin and forget; it cannot edit a fact, merge pages or run the learning pass.
@MainActor
package struct RemoteMemory {
    package init(api: IronPetAPI) {
        self.api = api
    }

    package let api: IronPetAPI

    private func memory() throws -> MemoryAPI {
        guard let memory = api.memory else { throw RemoteFailure(status: 503, code: "unavailable", message: "Ghost's memory is not available right now") }
        return memory
    }

    private func notFound(_ what: String) -> RemoteFailure { RemoteFailure(status: 404, code: "not_found", message: "no \(what) with that id") }

    /// The list for a chip (`all`, `people`, ...) and a search text.
    package func list(filter: String?, query: String?) throws -> [String: Any] {
        guard let chip = MemoryFilter(rawValue: filter ?? "all") else { throw RemoteFailure.invalid("filter must be one of \(MemoryFilter.allCases.map(\.rawValue).joined(separator: ", "))") }
        let memory = try memory()
        let text = query ?? ""
        let rows = memory.browseRows()
        let list = MemoryBrowser.list(rows, filter: chip, query: text)
        var others: [String: Int] = [:]
        if list.searching && list.rows.isEmpty {
            for match in MemoryBrowser.otherMatches(rows, query: text, excluding: chip) { others[match.filter.rawValue] = match.count }
            if chip != .all {
                let all = MemoryBrowser.list(rows, filter: .all, query: text).rows.count
                if all > 0 { others[MemoryFilter.all.rawValue] = all }
            }
        }
        return RemoteWire.object(RemoteMemoryList(pages: list.rows.map {
            RemoteMemoryRow(id: $0.ref, type: $0.type.rawValue, typeLabel: $0.type.label, name: $0.name, summary: $0.summary,
                            factCount: $0.factCount, updated: $0.updated, matchedInFact: $0.matchedInFact)
        }, total: list.total, countLabel: list.countLabel, otherMatches: others))
    }

    package func page(_ ref: String) throws -> [String: Any] {
        guard let detail = try memory().detail(ref) else { throw notFound("page") }
        func fact(_ claim: MemoryClaim) -> RemoteMemoryFact {
            RemoteMemoryFact(id: claim.ref, text: claim.text, date: claim.date, pinned: claim.pinned, sources: claim.sources, replaced: claim.invalidAt)
        }
        return RemoteWire.object(RemoteMemoryPage(
            id: detail.entity.ref, type: detail.entity.type.rawValue, typeLabel: detail.entity.type.label, title: detail.title,
            aliases: detail.entity.aliases, identifiers: detail.entity.identifiers, facts: detail.facts.map(fact),
            earlier: detail.earlier.map(fact),
            linkGroups: detail.linkGroups.map { group in
                RemoteMemoryLinkGroup(title: group.title, links: group.items.map {
                    RemoteMemoryLink(id: $0.ref, name: $0.name, type: $0.type.rawValue, typeLabel: $0.type.label, mentions: $0.count, lastSeen: $0.lastSeen)
                })
            }, updated: detail.updated, firstSeen: detail.firstSeen))
    }

    package func pin(_ ref: String, pinned: Bool) throws -> [String: Any] {
        let memory = try memory()
        guard let claim = memory.claim(ref: ref), memory.setPinned(claim.id, pinned) else { throw notFound("fact") }
        return ["id": ref, "pinned": pinned]
    }

    package func forgetFact(_ ref: String) throws -> [String: Any] {
        let memory = try memory()
        guard let claim = memory.claim(ref: ref), memory.forgetClaim(claim.id) else { throw notFound("fact") }
        return ["forgotten": ref]
    }

    package func forgetPage(_ ref: String) throws -> [String: Any] {
        let memory = try memory()
        guard let detail = memory.detail(ref), memory.forgetPage(detail.entity.id) else { throw notFound("page") }
        return ["forgotten": ref]
    }
}
