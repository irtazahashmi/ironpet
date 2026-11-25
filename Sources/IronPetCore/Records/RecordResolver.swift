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

    private let refs: RecordRefs

    package init(refs: RecordRefs) {
        self.refs = refs
    }

    /// The record an id names. An old id must be the key of exactly one record: when two kinds share it, the caller must use a ref.
    package func resolve(_ id: String) -> Result<Found, RecordError> {
        if RecordID.parse(id) != nil, let found = refs.lookup(id) {
            return .success(Found(kind: found.kind, key: found.key, ref: id))
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
