import Foundation
import IronPetKit

extension TaskItem: QuickFilterSubject {
    package var filterTitle: String { title }
    package var filterNotes: String { notes }
    package var filterStatus: String { status.rawValue }
    package var filterSource: String { source.rawValue }
    package var filterWaitingOn: String? { waitingOn }
    package var filterDue: Date? { due }
    package var filterLabels: [String: String] { labels }
}

/// Checks what an agent sends for a quick filter before it is stored.
package enum QuickFilterValidator {
    package static let maxFilters = 30
    package static let maxName = 40
    /// The chip that clears the filter. A saved filter cannot take its name.
    package static let allName = "All"

    /// The query as a JSON value. A JSON string is accepted too, since agents often send the object as text. The error names the bad node.
    package static func query(_ value: Any?) throws -> (node: QuickFilterNode, json: RemoteJSON) {
        guard var raw = value, !(raw is NSNull) else { throw TaskError(message: "query is required: an object such as {\"and\": [...]}") }
        if let text = raw as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                throw TaskError(message: "query is a string that is not JSON")
            }
            raw = parsed
        }
        do {
            let node = try QuickFilterNode.parse(raw)
            guard let json = RemoteJSON(foundation: raw) else { throw TaskError(message: "query is not JSON") }
            return (node, json)
        } catch let error as QuickFilterError {
            throw TaskError(message: "invalid query, \(error.description)")
        }
    }

    package static func name(_ value: Any?) throws -> String {
        guard let raw = value as? String else { throw TaskError(message: "name must be a string") }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !name.isEmpty else { throw TaskError(message: "name is empty") }
        guard name.count <= maxName else { throw TaskError(message: "name is longer than \(maxName) characters") }
        guard name.caseInsensitiveCompare(allName) != .orderedSame else { throw TaskError(message: "\"\(allName)\" is the chip that shows every task; pick another name") }
        guard !BuiltInQuickFilters.isReservedName(name) else { throw TaskError(message: "\"\(name)\" is a built-in chip; pick another name") }
        return name
    }

    /// A slug the agent may choose for a new filter: lower case letters, digits, `-` and `_`.
    package static func slug(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String, !raw.isEmpty, raw.count <= maxName,
              raw.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }) else {
            throw TaskError(message: "id must be 1 to \(maxName) characters: lower case letters, digits, \"-\" and \"_\"")
        }
        return raw
    }

    package static func makeID(from name: String, taken: Set<String>) -> String {
        // ASCII only, so the id passes `slug` when the agent sends it back to edit the filter.
        let base = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }.prefix(30))
            .split(separator: "-").joined(separator: "-")
        let stem = base.isEmpty ? "filter" : base
        guard taken.contains(stem) else { return stem }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }
}

/// The saved quick filters. They live in `config.json` under `tasks.quickFilters`, so they follow the settings patterns:
/// hand edits are picked up, and every change fires `settings.changed` for the phone.
extension TasksAPI {
    /// Every saved filter in chip order, including ones this build cannot read.
    package var quickFilters: [QuickFilter] {
        quickFilterStorage.sorted { ($0.order, $0.name.lowercased(), $0.id) < ($1.order, $1.name.lowercased(), $1.id) }
    }

    package func quickFilter(_ id: String) -> QuickFilter? { quickFilterStorage.first { $0.id == id } }

    /// Adds a filter, or replaces the one with this id. Nothing is stored when the query or the name is invalid.
    @discardableResult
    package func upsertQuickFilter(id: String?, name: Any?, query: Any?) throws -> QuickFilter {
        let name = try QuickFilterValidator.name(name)
        let parsed = try QuickFilterValidator.query(query)
        var filters = quickFilters
        if let clash = filters.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.id != id }) {
            throw APIError.invalid("a quick filter named \"\(clash.name)\" already exists (id \(clash.id)); pass that id to change it")
        }
        let saved: QuickFilter
        if let id, let index = filters.firstIndex(where: { $0.id == id }) {
            filters[index].name = name
            filters[index].query = parsed.json
            saved = filters[index]
        } else {
            guard filters.count < QuickFilterValidator.maxFilters else { throw APIError.invalid("at most \(QuickFilterValidator.maxFilters) quick filters") }
            if let id, BuiltInQuickFilters.isBuiltIn(id) { throw APIError.invalid("\"\(id)\" is a built-in quick filter and cannot be saved under that id") }
            // Built-in ids count as taken, so a generated id never clashes with one.
            let taken = Set(filters.map(\.id)).union(BuiltInQuickFilters.all.map(\.id))
            if let id, taken.contains(id) { throw APIError.invalid("a quick filter with id \"\(id)\" already exists") }
            saved = QuickFilter(id: id ?? QuickFilterValidator.makeID(from: name, taken: taken), name: name, query: parsed.json,
                                order: (filters.map(\.order).max() ?? -1) + 1)
            filters.append(saved)
        }
        storeQuickFilters(filters)
        return saved
    }

    package func deleteQuickFilter(_ id: String) throws {
        var filters = quickFilters
        guard filters.contains(where: { $0.id == id }) else { throw APIError.notFound("no quick filter with id \"\(id)\"") }
        filters.removeAll { $0.id == id }
        storeQuickFilters(filters)
    }

    /// Puts the filters named in `ids` first, in that order. Filters not named keep their order after them.
    package func reorderQuickFilters(_ ids: [String]) throws {
        let filters = quickFilters
        if let unknown = ids.first(where: { id in !filters.contains { $0.id == id } }) { throw APIError.notFound("no quick filter with id \"\(unknown)\"") }
        guard Set(ids).count == ids.count else { throw APIError.invalid("ids lists a quick filter twice") }
        let ordered = ids.compactMap { id in filters.first { $0.id == id } } + filters.filter { !ids.contains($0.id) }
        storeQuickFilters(ordered)
    }

    /// Moves one filter a step toward the front (`-1`) or the back (`1`).
    package func moveQuickFilter(_ id: String, by step: Int) throws {
        var filters = quickFilters
        guard let index = filters.firstIndex(where: { $0.id == id }) else { throw APIError.notFound("no quick filter with id \"\(id)\"") }
        let target = min(max(index + step, 0), filters.count - 1)
        guard target != index else { return }
        filters.insert(filters.remove(at: index), at: target)
        storeQuickFilters(filters)
    }

    private func storeQuickFilters(_ filters: [QuickFilter]) {
        var numbered = filters
        for index in numbered.indices { numbered[index].order = index }
        setQuickFilterStorage(numbered)
    }
}
