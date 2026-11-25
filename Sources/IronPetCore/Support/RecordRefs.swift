import Foundation

/// The public id of each record, kept in `ironpet.db` (`record_refs`). A ref names one record of one kind by that record's key: a
/// task's id, a job's id, an automation's id or a filter's id. A ref never changes and is never reused. The key stays the same, so
/// an old id (the key itself) keeps resolving to the same record, and stored references to it need no rewrite.
package struct RecordRefs {
    /// Version 546 is above every version in the app (the memory migrations are 544 and 545). Existing tasks and jobs get refs now;
    /// automations and filters get theirs the first time they are listed, since they are not in the database.
    package static let migrations: [Database.Migration] = [
        .init(546, "records: public refs for tasks and jobs", sql: """
            CREATE TABLE record_refs(ref TEXT PRIMARY KEY, kind TEXT NOT NULL, key TEXT NOT NULL, UNIQUE(kind, key)) WITHOUT ROWID;
            INSERT OR IGNORE INTO record_refs(ref, kind, key) SELECT 'task_' || lower(hex(randomblob(3))), 'task', id FROM task_items;
            INSERT OR IGNORE INTO record_refs(ref, kind, key) SELECT 'job_' || lower(hex(randomblob(3))), 'job', id FROM jobs;
            """),
    ]

    private let database: Database

    package init(database: Database) {
        self.database = database
    }

    /// The ref of one record, created when it has none yet. Nil when the database is unavailable.
    package func ref(_ kind: RecordKind, _ key: String) -> String? {
        refs(kind, [key])[key]
    }

    /// The refs of several records of one kind, created where missing. One write, so a list of tasks costs one round trip.
    package func refs(_ kind: RecordKind, _ keys: [String]) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        do {
            return try database.write { db in
                var known: [String: String] = [:]
                for row in try db.rows("SELECT key, ref FROM record_refs WHERE kind = ?", [kind.rawValue]) {
                    if let key = row[0] as? String, let ref = row[1] as? String { known[key] = ref }
                }
                for key in Set(keys) where known[key] == nil {
                    let ref = try RecordID.make(kind, taken: { ref in
                        try !db.rows("SELECT 1 FROM record_refs WHERE ref = ?", [ref]).isEmpty
                    })
                    try db.execute("INSERT INTO record_refs(ref, kind, key) VALUES(?, ?, ?)", [ref, kind.rawValue, key])
                    known[key] = ref
                }
                return known.filter { keys.contains($0.key) }
            }
        } catch {
            NSLog("ironpet: could not assign record ids: \(error.localizedDescription)")
            return [:]
        }
    }

    /// The record a ref names: its kind and key. Nil for a ref that does not exist.
    package func lookup(_ ref: String) -> (kind: RecordKind, key: String)? {
        guard let row = try? database.read({ try $0.rows("SELECT kind, key FROM record_refs WHERE ref = ?", [ref]) }).first,
              let kind = (row[0] as? String).flatMap(RecordKind.init(rawValue:)), let key = row[1] as? String else { return nil }
        return (kind, key)
    }

    /// Every record whose key is `key`, across kinds. An old id can match more than one kind, such as a task and a filter with the same slug.
    package func lookup(key: String) -> [(kind: RecordKind, ref: String)] {
        let rows = (try? database.read({ try $0.rows("SELECT kind, ref FROM record_refs WHERE key = ?", [key]) })) ?? []
        return rows.compactMap { row in
            guard let kind = (row[0] as? String).flatMap(RecordKind.init(rawValue:)), let ref = row[1] as? String else { return nil }
            return (kind, ref)
        }
    }
}
