import Foundation
#if canImport(Combine)
import Combine
#endif

/// The inbox Ghost keeps, in `ironpet.db`: action items from meeting summaries and things watcher automations and agents found. An
/// item stays until the user marks it done or removes it. The store has no task list; the task tables are dropped by migration 590.
@MainActor
package final class TaskStore {
    /// Fires before `suggestions` change.
    package let changes = ChangeSignal()
    package private(set) var suggestions: [TaskSuggestion] = [] { willSet { changes.send() } }

    package nonisolated static let migrations: [Database.Migration] = [
        .init(200, "tasks: items, links, events, suggestions", sql: """
            CREATE TABLE task_items(id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT NOT NULL, status TEXT NOT NULL,
                                    source TEXT NOT NULL, due REAL, created REAL NOT NULL, updated REAL NOT NULL, closed REAL) WITHOUT ROWID;
            CREATE TABLE task_links(task TEXT NOT NULL, position INTEGER NOT NULL, kind TEXT NOT NULL, ref TEXT NOT NULL, label TEXT,
                                    PRIMARY KEY(task, position)) WITHOUT ROWID;
            CREATE TABLE task_events(id INTEGER PRIMARY KEY AUTOINCREMENT, task TEXT NOT NULL, at REAL NOT NULL, by TEXT NOT NULL,
                                     kind TEXT NOT NULL, detail TEXT NOT NULL);
            CREATE INDEX task_events_by_task ON task_events(task, id);
            CREATE TABLE task_suggestions(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, meeting TEXT NOT NULL,
                                          created REAL NOT NULL) WITHOUT ROWID;
            """),
        // Versions after 300 because they came after screen capture's. A development build numbered them 201 to 203, so a
        // database may already have these changes: each step checks before it runs.
        .init(303, "tasks: suggestions from automations") { db in
            if try !TaskStore.columns(db, "task_suggestions").contains("automation") {
                try db.script("""
                    CREATE TABLE task_suggestions_303(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                      meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL,
                                                      CHECK ((meeting IS NULL) <> (automation IS NULL))) WITHOUT ROWID;
                    INSERT INTO task_suggestions_303(id, title, due, meeting, created) SELECT id, title, due, meeting, created FROM task_suggestions;
                    DROP TABLE task_suggestions;
                    ALTER TABLE task_suggestions_303 RENAME TO task_suggestions;
                    """)
            }
            try db.script("""
                CREATE TABLE IF NOT EXISTS task_suggestion_keys(automation TEXT NOT NULL, key TEXT NOT NULL, at REAL NOT NULL,
                                                                PRIMARY KEY(automation, key)) WITHOUT ROWID;
                """)
        },
        .init(304, "tasks: waiting on someone else") { db in
            for table in ["task_items", "task_suggestions"] where try !TaskStore.columns(db, table).contains("waiting_on") {
                try db.execute("ALTER TABLE \(table) ADD COLUMN waiting_on TEXT")
            }
        },
        .init(305, "tasks: due reminders", sql: """
            CREATE TABLE IF NOT EXISTS task_due_marks(task TEXT PRIMARY KEY, due REAL NOT NULL, snoozed_until REAL) WITHOUT ROWID;
            """),
        // A table's CHECK cannot change in place, so the table is rebuilt with every row copied. `capture` holds the
        // fingerprint of a screen capture proposal, and exactly one of the three origin columns is set.
        .init(421, "tasks: suggestions from screen capture") { db in
            if try !TaskStore.columns(db, "task_suggestions").contains("capture") {
                try db.script("""
                    CREATE TABLE task_suggestions_421(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                      meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL, waiting_on TEXT,
                                                      capture TEXT, kind TEXT, target TEXT, changes TEXT, diff TEXT, quote TEXT, evidence TEXT,
                                                      CHECK ((meeting IS NOT NULL) + (automation IS NOT NULL) + (capture IS NOT NULL) = 1)) WITHOUT ROWID;
                    INSERT INTO task_suggestions_421(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on)
                        SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on FROM task_suggestions;
                    DROP TABLE task_suggestions;
                    ALTER TABLE task_suggestions_421 RENAME TO task_suggestions;
                    """)
            }
        },
        .init(422, "tasks: where a task or suggestion came from") { db in
            for table in ["task_items", "task_suggestions"] where try !TaskStore.columns(db, table).contains("source_ref") {
                try db.execute("ALTER TABLE \(table) ADD COLUMN source_ref TEXT")
            }
        },
        // Numbered above every migration in the app (usage's 430 is the highest), so a database already past 430 still runs it.
        // A resolved suggestion leaves task_suggestions, so this keeps what happened to each one for the batch that produced it.
        .init(431, "tasks: what became of each screen capture suggestion", sql: """
            CREATE TABLE IF NOT EXISTS task_suggestion_outcomes(id INTEGER PRIMARY KEY AUTOINCREMENT, send_log INTEGER NOT NULL,
                suggestion TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, quote TEXT NOT NULL DEFAULT '', outcome TEXT NOT NULL,
                task TEXT, note TEXT, at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS task_suggestion_outcomes_by_log ON task_suggestion_outcomes(send_log, id);
            """),
        // The in-app screen capture analysis is gone, so its proposals, their columns and the outcome log go with it. Suggestions from
        // meetings and automations are copied over unchanged. A table's CHECK cannot change in place, so the table is rebuilt.
        .init(441, "tasks: drop screen capture suggestions and outcomes") { db in
            try db.script("""
                CREATE TABLE task_suggestions_441(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                  meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL, waiting_on TEXT,
                                                  source_ref TEXT, CHECK ((meeting IS NULL) <> (automation IS NULL))) WITHOUT ROWID;
                INSERT INTO task_suggestions_441(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref)
                    SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref
                    FROM task_suggestions WHERE meeting IS NOT NULL OR automation IS NOT NULL;
                DROP TABLE task_suggestions;
                ALTER TABLE task_suggestions_441 RENAME TO task_suggestions;
                DROP TABLE IF EXISTS task_suggestion_outcomes;
                """)
        },
        // Numbered above every migration in the app (memory's 510 is the highest), so a database already past 510 still runs it.
        .init(520, "tasks: labels", sql: """
            CREATE TABLE IF NOT EXISTS task_labels(task TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
                                                   PRIMARY KEY(task, key)) WITHOUT ROWID;
            """),
        // The task scan files suggestions that belong to no meeting and no automation, and some of them change an existing task. The
        // table's CHECK cannot change in place, so it is rebuilt: exactly one of meeting, automation and scan names the origin. The
        // scan's cursors live here and not in memory, so Forget Everything does not make it read old text again.
        .init(550, "tasks: task scan suggestions, update suggestions and scan cursors") { db in
            try db.script("""
                CREATE TABLE task_suggestions_550(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                  meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL, waiting_on TEXT,
                                                  source_ref TEXT, scan INTEGER NOT NULL DEFAULT 0, update_task TEXT, update_title TEXT,
                                                  update_note TEXT, update_done INTEGER NOT NULL DEFAULT 0, update_waiting TEXT,
                                                  CHECK ((meeting IS NOT NULL) + (automation IS NOT NULL) + scan = 1)) WITHOUT ROWID;
                INSERT INTO task_suggestions_550(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref)
                    SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref FROM task_suggestions;
                DROP TABLE task_suggestions;
                ALTER TABLE task_suggestions_550 RENAME TO task_suggestions;
                CREATE TABLE IF NOT EXISTS task_scan_cursors(key TEXT PRIMARY KEY, item TEXT NOT NULL, at REAL NOT NULL) WITHOUT ROWID;
                """)
        },
        // Which install and which agent made a change. Old rows keep both columns empty. On `task_items` the columns name the last writer;
        // `task_events` names the writer of each event, so the creator is the node and agent of the `created` event.
        .init(552, "tasks: node and agent on every change") { db in
            for table in ["task_items", "task_events"] {
                let existing = try TaskStore.columns(db, table)
                for column in ["node_id", "agent_id"] where !existing.contains(column) {
                    try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) TEXT")
                }
            }
        },
        // The tickler: a task stays out of the list until `defer_until`. Nothing to fill in for existing tasks.
        .init(580, "tasks: defer until") { db in
            if !(try TaskStore.columns(db, "task_items")).contains("defer_until") {
                try db.execute("ALTER TABLE task_items ADD COLUMN defer_until REAL")
            }
        },
        // The task scan's clarify proposal on a new suggestion: context, area, two-minute and someday.
        .init(581, "tasks: clarify proposals on suggestions") { db in
            let existing = try TaskStore.columns(db, "task_suggestions")
            for (column, type) in [("clarify_context", "TEXT"), ("clarify_area", "TEXT"), ("clarify_two_minute", "INTEGER"),
                                   ("clarify_someday", "INTEGER")] where !existing.contains(column) {
                try db.execute("ALTER TABLE task_suggestions ADD COLUMN \(column) \(type)")
            }
        },
        // Waiting for: when the user asked. Tasks already waiting start from their last change.
        .init(583, "tasks: asked at") { db in
            if !(try TaskStore.columns(db, "task_items")).contains("asked_at") {
                try db.execute("ALTER TABLE task_items ADD COLUMN asked_at REAL")
                try db.execute("UPDATE task_items SET asked_at = updated WHERE waiting_on IS NOT NULL")
            }
        },
        // The task list, the board and the GTD views are gone, and every task with them. Nothing is exported. Inbox items from
        // meetings and automations keep their rows. The ones the task scan filed, and its proposed changes to tasks, go. A table's CHECK
        // cannot change in place, so `task_suggestions` is rebuilt without the columns the tasks needed. Every drop is `IF EXISTS`,
        // because a database below 580 never had some of these tables.
        .init(590, "inbox: drop the tasks, keep the suggestions") { db in
            try db.script("""
                DROP TABLE IF EXISTS task_items;
                DROP TABLE IF EXISTS task_links;
                DROP TABLE IF EXISTS task_events;
                DROP TABLE IF EXISTS task_labels;
                DROP TABLE IF EXISTS task_due_marks;
                DROP TABLE IF EXISTS task_scan_cursors;
                DROP TABLE IF EXISTS task_projects;
                DROP TABLE IF EXISTS task_areas;
                DROP TABLE IF EXISTS task_goals;
                DROP TABLE IF EXISTS task_key_results;
                CREATE TABLE task_suggestions_590(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                  meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL, waiting_on TEXT,
                                                  source_ref TEXT, CHECK ((meeting IS NULL) <> (automation IS NULL))) WITHOUT ROWID;
                INSERT INTO task_suggestions_590(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref)
                    SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref
                    FROM task_suggestions WHERE (meeting IS NOT NULL OR automation IS NOT NULL) AND update_task IS NULL;
                DROP TABLE task_suggestions;
                ALTER TABLE task_suggestions_590 RENAME TO task_suggestions;
                """)
            // The public ids of tasks and quick filters point at nothing now. Only a full database has the ref table.
            let hasRefs = try db.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'record_refs'")
            if !hasRefs.isEmpty { try db.execute("DELETE FROM record_refs WHERE kind IN ('task', 'filter')") }
        },
    ]

    /// A source reference as stored: a JSON object, keys sorted.
    package nonisolated static func refText(_ object: [String: Any]) -> String? { TaskRef.text(object) }

    /// The column names of `table`, empty when it does not exist.
    package nonisolated static func columns(_ db: Database.Connection, _ table: String) throws -> Set<String> {
        Set(try db.rows("SELECT name FROM pragma_table_info(?)", [table]).compactMap { $0[0] as? String })
    }

    /// Items one automation can have waiting. More wait in the watcher until the user marks some done or removes them.
    package static let maxPendingPerAutomation = 50
    /// How long an automation's suggested keys are remembered, so a removed item does not come back.
    package static let keepSuggestedKeysDays = 365

    /// Called after any change.
    package var onChange: (() -> Void)?
    /// Where changes are published for API clients: `suggestions.changed`.
    package weak var events: APIEventBus?

    func didChange() {
        events?.publish(.suggestionsChanged, id: nil)
        onChange?()
    }

    let database: Database
    let now: () -> Date
    private var lastPrune = Date.distantPast

    package init(database: Database, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.now = now
        prune()
        reload()
    }

    // MARK: Reading

    /// The public ids of records kept in the same database.
    package var records: RecordRefs { RecordRefs(database: database) }

    /// Why the database is unavailable, when the inbox is only in memory.
    package var unavailable: String? { database.unavailableReason }

    // MARK: Suggestions

    /// Stores meeting action items. Items already in the inbox are skipped.
    @discardableResult
    package func suggest(_ items: [(title: String, due: String?, waitingOn: String?)], meeting: URL) -> [TaskSuggestion] {
        store(items.map { TaskSuggestion.Draft(key: "", title: $0.title, due: $0.due, waitingOn: $0.waitingOn) }, origin: .meeting(meeting))
    }

    /// Stores what a watcher automation proposed. Besides the title check, a key this automation suggested before is
    /// left out, even after it was marked done or removed.
    @discardableResult
    package func suggest(_ drafts: [TaskSuggestion.Draft], automation id: String, name: String) -> [TaskSuggestion] {
        let seen = suggestedKeys(id)
        var keys = Set<String>()
        let fresh = drafts.filter { !seen.contains($0.key) && keys.insert($0.key).inserted }
        let waiting = suggestions.filter { if case .automation(let other, _) = $0.origin { return other == id } else { return false } }.count
        let name = TaskSuggestion.Draft.clean(name, limit: 100, newlines: false)
        return store(fresh, origin: .automation(id: id, name: name.isEmpty ? id : name), limit: Self.maxPendingPerAutomation - waiting)
    }

    /// Stores what an agent proposed through `inbox_add`. It goes through the same path as a watcher's `suggest_task`, so the
    /// same dedupe and limits apply. Agent suggestions share one source per origin kind (`agent:email`, `agent:pr`), so an id from
    /// mail never collides with an automation's id or with an id from another kind. `sourceRef` is the origin the agent gave.
    @discardableResult
    package func suggest(_ draft: TaskSuggestion.Draft, agent kind: TaskSource, sourceRef: String) -> [TaskSuggestion] {
        let id = "agent:\(kind.rawValue)"
        guard !suggestedKeys(id).contains(draft.key) else { return [] }
        let waiting = suggestions.filter { if case .automation(let other, _) = $0.origin { return other == id } else { return false } }.count
        return store([draft], origin: .automation(id: id, name: "\(kind.rawValue) agent"), limit: Self.maxPendingPerAutomation - waiting,
                     sourceRef: sourceRef)
    }

    private func store(_ drafts: [TaskSuggestion.Draft], origin: TaskSuggestion.Origin, limit: Int = .max,
                       sourceRef: String? = nil) -> [TaskSuggestion] {
        // Compared by `ActionItems.normalized`, so a regenerated summary that words an item with another case, spacing or
        // closing full stop does not offer it a second time.
        let existing = Set(suggestions.map { ActionItems.normalized($0.title) })
        let time = now()
        var added: [(key: String, suggestion: TaskSuggestion)] = []
        var taken = Set(suggestions.map(\.id))
        for draft in drafts where added.count < limit {
            guard let title = try? TaskValidator.title(draft.title), !existing.contains(ActionItems.normalized(title)),
                  !added.contains(where: { ActionItems.normalized($0.suggestion.title) == ActionItems.normalized(title) }) else { continue }
            let id = AutomationValidator.slug(title, taken: taken)
            taken.insert(id)
            let waitingOn = draft.waitingOn.flatMap { try? TaskValidator.waitingOn(String($0.prefix(TaskValidator.maxWaitingOn))) }
            let ref: [String: Any]
            switch origin {
            case .meeting(let folder):
                ref = ["ref": folder.path, "reason": "Action item from the meeting summary", "meeting": folder.path]
            case .automation(let automation, let name):
                ref = ["ref": automation, "reason": "Suggested by the \(name) watcher", "automation": automation,
                       "at": ISO8601DateFormatter().string(from: time)]
            }
            added.append((draft.key, TaskSuggestion(id: id, title: title, due: draft.due, notes: draft.notes, url: draft.url,
                                                    origin: origin, created: time, waitingOn: waitingOn,
                                                    sourceRef: sourceRef ?? draft.sourceRef ?? Self.refText(ref))))
        }
        guard !added.isEmpty else { return [] }
        do {
            try database.write { db in
                for (key, s) in added {
                    if case .automation(let id, _) = s.origin {
                        try db.execute("INSERT OR REPLACE INTO task_suggestion_keys(automation, key, at) VALUES(?, ?, ?)",
                                       [id, key, time.timeIntervalSince1970])
                    }
                    try Self.insert(s, db)
                }
            }
        } catch {
            NSLog("ironpet: could not store inbox items: \(error.localizedDescription)")
            return []
        }
        reload()
        didChange()
        return added.map(\.suggestion)
    }

    private static func insert(_ s: TaskSuggestion, _ db: Database.Connection) throws {
        var meeting: String?, automation: String?, name: String?
        switch s.origin {
        case .meeting(let folder): meeting = folder.path
        case .automation(let id, let n): (automation, name) = (id, n)
        }
        try db.execute("""
            INSERT INTO task_suggestions(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [s.id, s.title, s.due, s.notes, s.url?.absoluteString, meeting, automation, name, s.created.timeIntervalSince1970,
                  s.waitingOn, s.sourceRef])
    }

    private func suggestedKeys(_ automation: String) -> Set<String> {
        Set((try? database.read { db in
            try db.rows("SELECT key FROM task_suggestion_keys WHERE automation = ?", [automation]).compactMap { $0[0] as? String }
        }) ?? [])
    }

    /// Takes an item off the list because the user (or an agent) is done with it. Nothing else is created.
    package func done(_ suggestionID: String) throws {
        guard suggestions.contains(where: { $0.id == suggestionID }) else { throw TaskError(message: "no inbox item \"\(suggestionID)\"") }
        removeSuggestion(suggestionID)
    }

    /// Takes an item off the list because it is wrong or a duplicate. `note` is checked and not kept.
    package func remove(_ suggestionID: String, note: String? = nil) throws {
        guard suggestions.contains(where: { $0.id == suggestionID }) else { throw TaskError(message: "no inbox item \"\(suggestionID)\"") }
        _ = try note.map { try TaskValidator.notes($0) }
        removeSuggestion(suggestionID)
    }

    private func removeSuggestion(_ id: String) {
        try? database.write { try $0.execute("DELETE FROM task_suggestions WHERE id = ?", [id]) }
        reload()
        didChange()
    }

    // MARK: Storage

    /// Suggested keys older than `keepSuggestedKeysDays`, at launch and at most daily.
    package func prune() {
        let time = now()
        guard time.timeIntervalSince(lastPrune) > 86_400 else { return }
        lastPrune = time
        do {
            try database.write { db in
                try db.execute("DELETE FROM task_suggestion_keys WHERE at < ?",
                               [time.addingTimeInterval(-Double(Self.keepSuggestedKeysDays) * 86_400).timeIntervalSince1970])
            }
        } catch {
            NSLog("ironpet: could not prune the inbox: \(error.localizedDescription)")
        }
    }

    package func reload() {
        prune()
        do {
            let suggested = try database.read { db -> [TaskSuggestion] in
                try db.rows("""
                    SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref
                    FROM task_suggestions ORDER BY created, id
                    """).compactMap { row -> TaskSuggestion? in
                    guard let id = row[0] as? String, let title = row[1] as? String, let created = row[8] as? Double else { return nil }
                    let origin: TaskSuggestion.Origin
                    if let meeting = row[5] as? String {
                        origin = .meeting(URL(fileURLWithPath: meeting))
                    } else if let automation = row[6] as? String {
                        origin = .automation(id: automation, name: row[7] as? String ?? automation)
                    } else {
                        return nil
                    }
                    return TaskSuggestion(id: id, title: title, due: row[2] as? String, notes: row[3] as? String ?? "",
                                          url: (row[4] as? String).flatMap(URL.init(string:)), origin: origin,
                                          created: Date(timeIntervalSince1970: created), waitingOn: row[9] as? String,
                                          sourceRef: row[10] as? String)
                }
            }
            if suggested != suggestions { suggestions = suggested }
        } catch {
            NSLog("ironpet: could not read the inbox: \(error.localizedDescription)")
        }
    }
}

#if canImport(Combine)

extension TaskStore: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
