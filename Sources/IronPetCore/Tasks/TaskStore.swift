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
        // meetings and automations keep their rows. The ones the task scan filed, its proposed changes to tasks, and the items waiting on someone else go. A table's CHECK
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
                    FROM task_suggestions WHERE (meeting IS NOT NULL OR automation IS NOT NULL) AND update_task IS NULL AND waiting_on IS NULL;
                DROP TABLE task_suggestions;
                ALTER TABLE task_suggestions_590 RENAME TO task_suggestions;
                """)
            // The public ids of tasks and quick filters point at nothing now. Only a full database has the ref table.
            let hasRefs = try db.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'record_refs'")
            if !hasRefs.isEmpty { try db.execute("DELETE FROM record_refs WHERE kind IN ('task', 'filter')") }
        },
        // An item lists every place it came from, so a mail about a meeting's item adds a source instead of a second item. Each row gets
        // its one source from its origin and url. A key remembers the item it made, so the same id arriving again updates that item
        // while it is in the inbox. A resolved item keeps its reason here after it leaves the list.
        .init(591, "inbox: sources, key to item, resolved items") { db in
            try db.script("""
                CREATE TABLE IF NOT EXISTS task_suggestion_sources(suggestion TEXT NOT NULL, position INTEGER NOT NULL, kind TEXT NOT NULL,
                                                                   ref TEXT NOT NULL, url TEXT, label TEXT,
                                                                   PRIMARY KEY(suggestion, position)) WITHOUT ROWID;
                INSERT OR IGNORE INTO task_suggestion_sources(suggestion, position, kind, ref, url, label)
                    SELECT id, 0, CASE WHEN meeting IS NOT NULL THEN 'meeting' ELSE 'automation' END, COALESCE(meeting, automation), url,
                           CASE WHEN meeting IS NOT NULL THEN 'Meeting' ELSE automation_name END
                    FROM task_suggestions;
                CREATE TABLE IF NOT EXISTS task_suggestion_resolved(id INTEGER PRIMARY KEY AUTOINCREMENT, item TEXT NOT NULL, title TEXT NOT NULL,
                                                                    due TEXT, notes TEXT NOT NULL DEFAULT '', created REAL NOT NULL,
                                                                    resolved REAL NOT NULL, reason TEXT NOT NULL, sources TEXT NOT NULL);
                """)
            if try !TaskStore.columns(db, "task_suggestion_keys").contains("item") {
                try db.execute("ALTER TABLE task_suggestion_keys ADD COLUMN item TEXT")
            }
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
        let drafts = items.map { TaskSuggestion.Draft(key: "", title: $0.title, due: $0.due, waitingOn: $0.waitingOn) }
        return Self.added(file(drafts, origin: .meeting(meeting), scope: nil, sourceRef: nil, kind: .meeting, ref: meeting.path))
    }

    /// Stores what a watcher automation proposed. A key this automation suggested before updates its item while the item is in the
    /// inbox, and is left out after the item was marked done, removed or resolved. Returns the new items.
    @discardableResult
    package func suggest(_ drafts: [TaskSuggestion.Draft], automation id: String, name: String) -> [TaskSuggestion] {
        Self.added(file(drafts, automation: id, name: name))
    }

    /// `suggest` with what happened to each draft.
    package func file(_ drafts: [TaskSuggestion.Draft], automation id: String, name: String) -> [SuggestFiling] {
        let name = TaskSuggestion.Draft.clean(name, limit: 100, newlines: false)
        return file(drafts, origin: .automation(id: id, name: name.isEmpty ? id : name), scope: id, sourceRef: nil, kind: .automation, ref: id)
    }

    /// Stores what an agent proposed through `inbox_add`. It goes through the same path as a watcher's `suggest_task`, so the
    /// same dedupe and limits apply. Agent suggestions share one scope per origin kind (`agent:email`, `agent:pr`), so an id from
    /// mail never collides with an automation's id or with an id from another kind. `sourceRef` is the origin the agent gave.
    @discardableResult
    package func suggest(_ draft: TaskSuggestion.Draft, agent kind: TaskSource, sourceRef: String) -> [TaskSuggestion] {
        file(draft, agent: kind, sourceRef: sourceRef).compactMap { $0.change.keepsItem ? $0.item : nil }
    }

    /// `suggest(_:agent:sourceRef:)` with what happened.
    package func file(_ draft: TaskSuggestion.Draft, agent kind: TaskSource, sourceRef: String) -> [SuggestFiling] {
        let ref = (TaskJSON.refValue(sourceRef) as? [String: Any])?["ref"] as? String ?? ""
        return file([draft], origin: .automation(id: "agent:\(kind.rawValue)", name: "\(kind.rawValue) agent"), scope: "agent:\(kind.rawValue)",
                    sourceRef: sourceRef, kind: kind, ref: ref)
    }

    private static func added(_ filings: [SuggestFiling]) -> [TaskSuggestion] {
        filings.compactMap { $0.change == .added ? $0.item : nil }
    }

    /// The one path every draft takes. `scope` is the automation id or `agent:<kind>` the draft's id belongs to, nil for meetings.
    private func file(_ drafts: [TaskSuggestion.Draft], origin: TaskSuggestion.Origin, scope: String?, sourceRef: String?, kind: TaskSource,
                      ref: String) -> [SuggestFiling] {
        // Compared by `ActionItems.normalized`, so a regenerated summary that words an item with another case, spacing or
        // closing full stop does not offer it a second time.
        let time = now()
        var items = suggestions
        var filings: [SuggestFiling] = []
        var writes: [(TaskSuggestion, isNew: Bool, key: String?)] = []
        var newKeys: [(key: String, item: String?)] = []
        var taken = Set(items.map(\.id))
        var seenKeys = Set<String>()
        var waiting = scope.map { scope in items.filter { if case .automation(let other, _) = $0.origin { return other == scope } else { return false } }.count } ?? 0
        let known = scope.map(keyItems) ?? [:]
        var pendingKeys: [String: String?] = [:]

        func replace(_ item: TaskSuggestion) {
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
            if let index = writes.firstIndex(where: { $0.0.id == item.id }) { writes[index].0 = item }
        }

        for draft in drafts {
            let key = draft.key
            if scope != nil {
                guard seenKeys.insert(key).inserted else { filings.append(SuggestFiling(change: .ignored("id \"\(key)\" appears twice in one call"))); continue }
            }
            let source = InboxSource(kind: kind, ref: ref, url: draft.url,
                                     label: Self.label(origin: origin, kind: kind))

            // 1. An id used before: update its item, or stay out when the item is gone.
            if scope != nil, let entry = pendingKeys[key] ?? known[key] {
                guard let itemID = entry, let current = items.first(where: { $0.id == itemID }) else {
                    filings.append(SuggestFiling(change: .ignored("this id was added before and the item is no longer in the inbox")))
                    continue
                }
                var changed = current
                let didChange = Self.apply(draft, source: source, to: &changed, replaceTitle: true)
                if didChange {
                    replace(changed)
                    if !writes.contains(where: { $0.0.id == changed.id }) { writes.append((changed, false, nil)) }
                }
                filings.append(SuggestFiling(change: didChange ? .updated : .ignored("this id is already in the inbox with the same text"), item: changed))
                continue
            }

            // 2. The caller named an existing item, or the url is one an item already has: add a source to it.
            if scope != nil {
                var target: TaskSuggestion?
                if let named = draft.sameAs?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
                    guard let found = items.first(where: { $0.id == named }) ?? self.itemForKey(named, scope: scope, items: items, pending: pendingKeys) else {
                        filings.append(SuggestFiling(change: .ignored("same_as \"\(named)\" is not an item in the inbox. It may have been done, removed or resolved, or the id is wrong. Nothing was added.")))
                        continue
                    }
                    target = found
                } else if let url = draft.url {
                    target = items.first { $0.sources.contains { $0.url.map(InboxSource.normalized) == InboxSource.normalized(url) } }
                }
                if let target {
                    var changed = target
                    _ = Self.apply(draft, source: source, to: &changed, replaceTitle: false)
                    replace(changed)
                    if !writes.contains(where: { $0.0.id == changed.id }) { writes.append((changed, false, nil)) }
                    pendingKeys[key] = .some(changed.id)
                    newKeys.append((key, changed.id))
                    filings.append(SuggestFiling(change: .merged, item: changed))
                    continue
                }
            }

            // 3. A new item.
            guard let title = try? TaskValidator.title(draft.title) else { filings.append(SuggestFiling(change: .ignored("bad title"))); continue }
            guard !items.contains(where: { ActionItems.normalized($0.title) == ActionItems.normalized(title) }) else {
                filings.append(SuggestFiling(change: .ignored("the title is already in the inbox")))
                continue
            }
            guard scope == nil || waiting < Self.maxPendingPerAutomation else {
                filings.append(SuggestFiling(change: .ignored("this source already has \(Self.maxPendingPerAutomation) items waiting")))
                continue
            }
            let id = AutomationValidator.slug(title, taken: taken)
            taken.insert(id)
            let waitingOn = draft.waitingOn.flatMap { try? TaskValidator.waitingOn(String($0.prefix(TaskValidator.maxWaitingOn))) }
            let reference: [String: Any]
            switch origin {
            case .meeting(let folder):
                reference = ["ref": folder.path, "reason": "Action item from the meeting summary", "meeting": folder.path]
            case .automation(let automation, let name):
                reference = ["ref": automation, "reason": "Suggested by the \(name) watcher", "automation": automation,
                             "at": ISO8601DateFormatter().string(from: time)]
            }
            let item = TaskSuggestion(id: id, title: title, due: draft.due, notes: draft.notes, url: draft.url, origin: origin, created: time,
                                      waitingOn: waitingOn, sourceRef: sourceRef ?? draft.sourceRef ?? Self.refText(reference), sources: [source])
            items.append(item)
            writes.append((item, true, scope == nil ? nil : key))
            if scope != nil { pendingKeys[key] = .some(id); newKeys.append((key, id)) }
            waiting += 1
            filings.append(SuggestFiling(change: .added, item: item))
        }
        guard !writes.isEmpty || !newKeys.isEmpty else { return filings }
        do {
            try database.write { db in
                for (key, item) in newKeys {
                    guard let scope else { continue }
                    try db.execute("INSERT OR REPLACE INTO task_suggestion_keys(automation, key, at, item) VALUES(?, ?, ?, ?)",
                                   [scope, key, time.timeIntervalSince1970, item])
                }
                for (item, isNew, _) in writes {
                    if isNew { try Self.insert(item, db) } else { try Self.update(item, db) }
                }
            }
        } catch {
            NSLog("ironpet: could not store inbox items: \(error.localizedDescription)")
            return drafts.map { _ in SuggestFiling(change: .ignored("the inbox could not be saved")) }
        }
        reload()
        didChange()
        return filings
    }

    private static func label(origin: TaskSuggestion.Origin, kind: TaskSource) -> String {
        switch origin {
        case .meeting: return "Meeting"
        case .automation(let id, let name): return id.hasPrefix("agent:") ? InboxSource.displayName(kind) : name
        }
    }

    /// Applies a draft to an item the draft is about. Returns whether anything changed. Text the draft leaves out stays as it is, so a
    /// follow-up that only carries a new due date keeps the title and notes. A merge keeps the title and the notes that are there.
    private static func apply(_ draft: TaskSuggestion.Draft, source: InboxSource, to item: inout TaskSuggestion, replaceTitle: Bool) -> Bool {
        let before = item
        if replaceTitle, let title = try? TaskValidator.title(draft.title) { item.title = title }
        if let due = draft.due { item.due = due }
        if !draft.notes.isEmpty, replaceTitle || item.notes.isEmpty { item.notes = draft.notes }
        // An update takes the new page. A merge keeps the page the item has, and the new one is listed as a source.
        if let url = draft.url, replaceTitle || item.url == nil { item.url = url }
        // A source adds a place only when it names something and is not one the item lists. The same reference with a new page
        // changes that source's page, so a follow-up does not list the mail twice.
        if source.url != nil || !source.ref.isEmpty {
            if let index = item.sources.firstIndex(where: { $0.isSame(as: source) }) {
                if let url = source.url, item.sources[index].url == nil || replaceTitle { item.sources[index].url = url }
            } else {
                item.sources.append(source)
            }
        }
        return item != before
    }

    /// The item a caller's own id names: an id it used in its own scope, or for an agent an id any kind of agent used.
    private func itemForKey(_ name: String, scope: String?, items: [TaskSuggestion], pending: [String: String?]) -> TaskSuggestion? {
        guard let scope else { return nil }
        if let id = (pending[name] ?? keyItems(scope)[name]) ?? nil, let item = items.first(where: { $0.id == id }) { return item }
        guard scope.hasPrefix("agent:") else { return nil }
        for other in agentScopes where other != scope {
            if let id = keyItems(other)[name] ?? nil, let item = items.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    /// Every key of a scope with the item it made, nil once the item left the inbox.
    private func keyItems(_ scope: String) -> [String: String?] {
        let rows = (try? database.read { db in try db.rows("SELECT key, item FROM task_suggestion_keys WHERE automation = ?", [scope]) }) ?? []
        var result: [String: String?] = [:]
        for row in rows { if let key = row[0] as? String { result[key] = .some(row[1] as? String) } }
        return result
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
        try writeSources(s, db)
    }

    private static func update(_ s: TaskSuggestion, _ db: Database.Connection) throws {
        try db.execute("UPDATE task_suggestions SET title = ?, due = ?, notes = ?, url = ? WHERE id = ?",
                       [s.title, s.due, s.notes, s.url?.absoluteString, s.id])
        try writeSources(s, db)
    }

    private static func writeSources(_ s: TaskSuggestion, _ db: Database.Connection) throws {
        try db.execute("DELETE FROM task_suggestion_sources WHERE suggestion = ?", [s.id])
        for (position, source) in s.sources.enumerated() {
            try db.execute("INSERT INTO task_suggestion_sources(suggestion, position, kind, ref, url, label) VALUES(?, ?, ?, ?, ?, ?)",
                           [s.id, position, source.kind.rawValue, source.ref, source.url?.absoluteString, source.label])
        }
    }

    // MARK: Done, remove, resolve

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

    /// Takes an item off the list because its source settled it (the mail was answered, the event passed). The reason is kept in a
    /// resolved record with the item's title, due date and sources, and the item's id stays ignored like a removed one.
    @discardableResult
    package func resolve(_ suggestionID: String, reason: String) throws -> ResolvedSuggestion {
        guard let item = suggestions.first(where: { $0.id == suggestionID }) else { throw TaskError(message: "no inbox item \"\(suggestionID)\"") }
        let reason = try Self.validReason(reason)
        let record = ResolvedSuggestion(id: item.id, title: item.title, reason: reason, resolved: now(), created: item.created, due: item.due,
                                        sources: item.sources)
        let sources = String(data: (try? JSONEncoder().encode(item.sources)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        try database.write { db in
            try db.execute("""
                INSERT INTO task_suggestion_resolved(item, title, due, notes, created, resolved, reason, sources) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """, [item.id, item.title, item.due, item.notes, item.created.timeIntervalSince1970, record.resolved.timeIntervalSince1970,
                      reason, sources])
        }
        removeSuggestion(item.id)
        return record
    }

    /// The reason on one line, up to 200 characters.
    package static func validReason(_ value: String) throws -> String {
        let reason = TaskSuggestion.Draft.clean(value, limit: 200, newlines: false)
        guard !reason.isEmpty else { throw TaskError(message: "reason is required, for example \"answered\"") }
        return reason
    }

    /// Items that were resolved, newest first.
    package func resolved(limit: Int = 100) -> [ResolvedSuggestion] {
        let rows = (try? database.read { db in
            try db.rows("""
                SELECT item, title, due, created, resolved, reason, sources FROM task_suggestion_resolved ORDER BY resolved DESC, id DESC LIMIT ?
                """, [limit])
        }) ?? []
        return rows.compactMap { row in
            guard let id = row[0] as? String, let title = row[1] as? String, let created = row[3] as? Double, let resolved = row[4] as? Double,
                  let reason = row[5] as? String else { return nil }
            let sources = (row[6] as? String).flatMap { try? JSONDecoder().decode([InboxSource].self, from: Data($0.utf8)) } ?? []
            return ResolvedSuggestion(id: id, title: title, reason: reason, resolved: Date(timeIntervalSince1970: resolved),
                                      created: Date(timeIntervalSince1970: created), due: row[2] as? String, sources: sources)
        }
    }

    /// The item an id names: an item id, or an id the caller used when it added the item (a mail id) in one of `scopes`.
    package func item(named name: String, scopes: [String]) -> TaskSuggestion? {
        if let item = suggestions.first(where: { $0.id == name }) { return item }
        for scope in scopes {
            if let id = keyItems(scope)[name] ?? nil, let item = suggestions.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    /// The scopes of every kind of agent, for resolving an item by the id the agent added it under.
    package var agentScopes: [String] { TaskSource.originKinds.map { "agent:\($0.rawValue)" } }

    private func removeSuggestion(_ id: String) {
        try? database.write {
            try $0.execute("DELETE FROM task_suggestions WHERE id = ?", [id])
            try $0.execute("DELETE FROM task_suggestion_sources WHERE suggestion = ?", [id])
            // The keys stay, so the same id arriving again is ignored. They stop naming the item, so a later item that gets the
            // same id is not changed by an old key.
            try $0.execute("UPDATE task_suggestion_keys SET item = NULL WHERE item = ?", [id])
        }
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
                let cutoff = time.addingTimeInterval(-Double(Self.keepSuggestedKeysDays) * 86_400).timeIntervalSince1970
                try db.execute("DELETE FROM task_suggestion_keys WHERE at < ?", [cutoff])
                try db.execute("DELETE FROM task_suggestion_resolved WHERE resolved < ?", [cutoff])
            }
        } catch {
            NSLog("ironpet: could not prune the inbox: \(error.localizedDescription)")
        }
    }

    package func reload() {
        prune()
        do {
            let suggested = try database.read { db -> [TaskSuggestion] in
                var sources: [String: [InboxSource]] = [:]
                for row in try db.rows("SELECT suggestion, kind, ref, url, label FROM task_suggestion_sources ORDER BY suggestion, position") {
                    guard let id = row[0] as? String, let kind = (row[1] as? String).flatMap(TaskSource.init(rawValue:)), let ref = row[2] as? String else { continue }
                    sources[id, default: []].append(InboxSource(kind: kind, ref: ref, url: (row[3] as? String).flatMap(URL.init(string:)), label: row[4] as? String))
                }
                return try db.rows("""
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
                                          sourceRef: row[10] as? String, sources: sources[id])
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
