import Foundation

/// The message for an id that names no record, or names more than one.
package struct RecordError: Error, Equatable {
    package let message: String
}

/// Resolves an id to the record it names: a public `<prefix>_<hex>` id, or an old id that is the key of a task, a job, an automation
/// or a filter. The record itself is read by the API that owns its kind, so this only says which kind and which key.
package struct RecordResolver {
    package struct Found: Equatable {
        package let kind: RecordKind
        /// The record's own id in its owning store (a task's slug, a job's `job-…` id, an automation's id, a filter's id).
        package let key: String
        package let ref: String
    }

    /// Reads one record of a kind, as the JSON `get` returns. The reader names the owner's answer; `get` adds `kind` and `ref`.
    package typealias Reader = @MainActor (String) async -> Result<[String: Any], RecordError>

    private let refs: RecordRefs
    private let readers: [RecordKind: Reader]

    /// Kinds whose owner keeps the ref beside the record (memory pages and claims), so it is not in `record_refs` and is its own key.
    /// Their reader says when nothing has that ref.
    private static let ownRefs: Set<RecordKind> = [.page, .claim]

    package init(refs: RecordRefs, readers: [RecordKind: Reader] = [:]) {
        self.refs = refs
        self.readers = readers
    }

    /// The record's JSON through the reader of its kind. Nil when that kind has no reader yet.
    @MainActor package func read(_ found: Found) async -> Result<[String: Any], RecordError>? {
        guard let reader = readers[found.kind] else { return nil }
        switch await reader(found.key) {
        case .success(var object):
            object["kind"] = found.kind.rawValue
            object["ref"] = found.ref
            return .success(object)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The record an id names. An old id must be the key of exactly one record: when two kinds share it, the caller must use a ref.
    package func resolve(_ id: String) -> Result<Found, RecordError> {
        if let parsed = RecordID.parse(id) {
            if let found = refs.lookup(id) { return .success(Found(kind: found.kind, key: found.key, ref: id)) }
            if Self.ownRefs.contains(parsed.kind) { return .success(Found(kind: parsed.kind, key: id, ref: id)) }
        }
        let matches = refs.lookup(key: id)
        switch matches.count {
        case 0:
            return .failure(RecordError(message: "no record with id \(id)"))
        case 1:
            return .success(Found(kind: matches[0].kind, key: id, ref: matches[0].ref))
        default:
            let ids = matches.map(\.ref).sorted().joined(separator: ", ")
            return .failure(RecordError(message: "\(id) names more than one record; use one of its ids: \(ids)"))
        }
    }
}
