import Foundation
#if canImport(Combine)
import Combine
#endif

/// The task list Ghost keeps, in `ironpet.db`. The agent owns it: it creates, updates and closes tasks through `call`
/// (MCP tools and the CLI). The UI can only mark a task done, delete it, and add or skip suggestions from meetings and
/// watcher automations.
/// Every change is a row in `task_events`, so nothing an agent rewrites is lost.
@MainActor
package final class TaskStore {
    /// Fires before `tasks` or `suggestions` change.
    package let changes = ChangeSignal()
    package private(set) var tasks: [TaskItem] = [] { willSet { changes.send() } }
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
        .init(570, "tasks: defer until") { db in
            if !(try TaskStore.columns(db, "task_items")).contains("defer_until") {
                try db.execute("ALTER TABLE task_items ADD COLUMN defer_until REAL")
            }
        },
        // The task scan's clarify proposal on a new suggestion: context, area, two-minute and someday.
        .init(571, "tasks: clarify proposals on suggestions") { db in
            let existing = try TaskStore.columns(db, "task_suggestions")
            for (column, type) in [("clarify_context", "TEXT"), ("clarify_area", "TEXT"), ("clarify_two_minute", "INTEGER"),
                                   ("clarify_someday", "INTEGER")] where !existing.contains(column) {
                try db.execute("ALTER TABLE task_suggestions ADD COLUMN \(column) \(type)")
            }
        },
    ]

    /// A source reference as stored: a JSON object, keys sorted.
    package nonisolated static func refText(_ object: [String: Any]) -> String? { TaskRef.text(object) }

    /// The column names of `table`, empty when it does not exist.
    package nonisolated static func columns(_ db: Database.Connection, _ table: String) throws -> Set<String> {
        Set(try db.rows("SELECT name FROM pragma_table_info(?)", [table]).compactMap { $0[0] as? String })
    }

    /// Suggestions one automation can have waiting. More wait in the watcher until the user adds or skips some.
    package static let maxPendingPerAutomation = 50
    /// Suggestions the task scan can have waiting. The scan files no more until the user adds or skips some.
    package static let maxPendingScan = 50
    /// Longest note an update suggestion may append.
    package static let maxUpdateNote = 500
    /// How long an automation's suggested keys are remembered, so a skipped one does not come back.
    package static let keepSuggestedKeysDays = 365

    /// Called after any change, with the task's id (nil for suggestions).
    package var onChange: ((String?) -> Void)?
    /// Where changes are published for API clients: `tasks.changed` with the task's id, `suggestions.changed` without one.
    package weak var events: APIEventBus?

    private func didChange(_ id: String?) {
        events?.publish(id == nil ? .suggestionsChanged : .tasksChanged, id: id)
        onChange?(id)
    }

    private let database: Database
    private let now: () -> Date
    private let keepDoneDays: @MainActor () -> Int
    private var lastPrune = Date.distantPast

    package init(database: Database, now: @escaping () -> Date = Date.init,
         keepDoneDays: @escaping @MainActor () -> Int = { ConfigStore.shared.config.tasks.keepDoneDays }) {
        self.database = database
        self.now = now
        self.keepDoneDays = keepDoneDays
        prune()
        reload()
    }

    // MARK: Reading

    /// The public ids of tasks, filters and other records kept in the same database.
    package var records: RecordRefs { RecordRefs(database: database) }

    /// Why the database is unavailable, when tasks are only in memory.
    package var unavailable: String? { database.unavailableReason }

    package func task(_ id: String) -> TaskItem? { tasks.first { $0.id == id } }

    /// Open tasks first (needs you, in progress, backlog), then done, newest first within each.
    package var ordered: [TaskItem] {
        let rank: [TaskStatus: Int] = [.needsYou: 0, .inProgress: 1, .backlog: 2, .someday: 3, .done: 4]
        return tasks.sorted { a, b in
            if rank[a.status]! != rank[b.status]! { return rank[a.status]! < rank[b.status]! }
            return (a.closed ?? a.updated) > (b.closed ?? b.updated)
        }
    }

    /// What the Tasks section counts: the user's own work that is moving or waiting on them. Tasks waiting on someone else
    /// are left out.
    package var activeCount: Int {
        tasks.filter { $0.waitingOn == nil && !$0.isDeferred(now: now()) && ($0.status == .needsYou || $0.status == .inProgress) }.count
    }

    package func history(_ id: String) -> [TaskEvent] {
        (try? database.read { db in
            try db.rows("SELECT at, by, kind, detail FROM task_events WHERE task = ? ORDER BY id", [id]).compactMap { row in
                guard let at = row[0] as? Double, let by = row[1] as? String,
                      let kind = (row[2] as? String).flatMap(TaskEvent.Kind.init(rawValue:)) else { return nil }
                return TaskEvent(at: Date(timeIntervalSince1970: at), by: by, kind: kind, detail: row[3] as? String ?? "")
            }
        }) ?? []
    }

    // MARK: Changing

    @discardableResult
    package func create(title: String, notes: String = "", status: TaskStatus = .backlog, source: TaskSource, due: Date? = nil,
                links: [TaskLink] = [], waitingOn: String? = nil, sourceRef: String? = nil, labels: [String: String] = [:],
                deferUntil: Date? = nil, by: String) throws -> TaskItem {
        guard labels.count <= TaskValidator.maxLabels else { throw TaskError(message: "at most \(TaskValidator.maxLabels) labels") }
        let title = try TaskValidator.title(title)
        let notes = try TaskValidator.notes(notes)
        let waitingOn = try TaskValidator.waitingOn(waitingOn)
        let id = AutomationValidator.slug(title, taken: Set(tasks.map(\.id)).union(deletedIDs()))
        let time = now()
        let item = TaskItem(id: id, title: title, notes: notes, status: status, source: source, due: due, links: links,
                            created: time, updated: time, closed: status == .done ? time : nil, waitingOn: waitingOn, sourceRef: sourceRef, labels: labels,
                            deferUntil: deferUntil)
        try database.write { db in
            try Self.save(item, db)
            try Self.log(db, id, time, by, .created, "\(status.rawValue): \(title)" + (waitingOn.map { " (waiting on \($0))" } ?? "")
                         + (sourceRef.map { " [source: \(source.rawValue) \($0)]" } ?? "")
                         + (labels.isEmpty ? "" : " [labels: \(Self.describe(labels))]"))
        }
        reload()
        didChange(id)
        return task(id) ?? item
    }

    /// Applies the fields that are present. `note` goes to history only, so the agent can say why it changed something.
    @discardableResult
    package func update(_ id: String, title: String? = nil, notes: String? = nil, status: TaskStatus? = nil, due: Date?? = nil,
                links: [TaskLink]? = nil, waitingOn: String?? = nil, addLabels: [String: String] = [:], removeLabels: [String] = [],
                deferUntil: Date?? = nil, note: String? = nil, by: String) throws -> TaskItem {
        guard var item = task(id) else { throw TaskError(message: "no task with id \"\(id)\"") }
        let time = now()
        var events: [(TaskEvent.Kind, String)] = []
        if let title {
            let title = try TaskValidator.title(title)
            if title != item.title { events.append((.edited, "title: \(title)")); item.title = title }
        }
        if let notes {
            let notes = try TaskValidator.notes(notes)
            if notes != item.notes { events.append((.edited, "notes")); item.notes = notes }
        }
        if let due, due != item.due {
            item.due = due
            events.append((.edited, "due: \(due.map { ISO8601DateFormatter().string(from: $0) } ?? "none")"))
        }
        if let deferUntil, deferUntil != item.deferUntil {
            item.deferUntil = deferUntil
            events.append((.edited, "defer until: \(deferUntil.map { ISO8601DateFormatter().string(from: $0) } ?? "none")"))
        }
        if let links, links != item.links { item.links = links; events.append((.edited, "links: \(links.count)")) }
        if let waitingOn {
            let waitingOn = try TaskValidator.waitingOn(waitingOn)
            if waitingOn != item.waitingOn { item.waitingOn = waitingOn; events.append((.edited, "waiting on: \(waitingOn ?? "none")")) }
        }
        if !addLabels.isEmpty || !removeLabels.isEmpty {
            var labels = item.labels
            for key in removeLabels { labels[key] = nil }
            for (key, value) in addLabels { labels[key] = value }
            guard labels.count <= TaskValidator.maxLabels else { throw TaskError(message: "at most \(TaskValidator.maxLabels) labels") }
            if labels != item.labels {
                let removed = Set(item.labels.keys).subtracting(labels.keys).sorted()
                let added = labels.filter { item.labels[$0.key] != $0.value }
                events.append((.edited, "labels: " + ((added.isEmpty ? [] : ["set \(Self.describe(added))"])
                                                      + (removed.isEmpty ? [] : ["removed \(removed.joined(separator: ", "))"])).joined(separator: "; ")))
                item.labels = labels
            }
        }
        if let status, status != item.status {
            events.append((status == .done ? .closed : .status, "\(item.status.rawValue) → \(status.rawValue)"))
            item.status = status
            item.closed = status == .done ? time : nil
        }
        if let note {
            let note = try TaskValidator.notes(note)
            if !note.isEmpty { events.append((.note, note)) }
        }
        guard !events.isEmpty else { return item }
        item.updated = time
        let changed = item
        try database.write { db in
            try Self.save(changed, db)
            for (kind, detail) in events { try Self.log(db, id, time, by, kind, detail) }
        }
        reload()
        didChange(id)
        return task(id) ?? changed
    }

    @discardableResult
    package func close(_ id: String, note: String? = nil, by: String) throws -> TaskItem {
        try update(id, status: .done, note: note, by: by)
    }

    package func delete(_ id: String, by: String) throws {
        guard let item = task(id) else { throw TaskError(message: "no task with id \"\(id)\"") }
        let time = now()
        try database.write { db in
            try db.execute("DELETE FROM task_items WHERE id = ?", [id])
            try db.execute("DELETE FROM task_links WHERE task = ?", [id])
            try db.execute("DELETE FROM task_labels WHERE task = ?", [id])
            try db.execute("DELETE FROM task_due_marks WHERE task = ?", [id])
            // The history stays until prune, so a deleted task can still be explained.
            try Self.log(db, id, time, by, .deleted, item.title)
        }
        reload()
        didChange(id)
    }

    /// `a=1, b=2`, keys sorted.
    package nonisolated static func describe(_ labels: [String: String]) -> String {
        TaskLabels.describe(labels)
    }

    /// Every label in use, sorted, for the filter menu.
    package var allLabels: [(key: String, value: String)] {
        Set(tasks.flatMap { $0.labels.map { [$0.key, $0.value] } }).sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }.map { (key: $0[0], value: $0[1]) }
    }

    // MARK: Suggestions

    /// Stores meeting action items as suggestions. Items already suggested or already a task with the same title are skipped.
    @discardableResult
    package func suggest(_ items: [(title: String, due: String?, waitingOn: String?)], meeting: URL) -> [TaskSuggestion] {
        store(items.map { TaskSuggestion.Draft(key: "", title: $0.title, due: $0.due, waitingOn: $0.waitingOn) }, origin: .meeting(meeting))
    }

    /// Stores what a watcher automation proposed. Besides the title check, a key this automation suggested before is
    /// left out, even after it was added or skipped.
    @discardableResult
    package func suggest(_ drafts: [TaskSuggestion.Draft], automation id: String, name: String) -> [TaskSuggestion] {
        let seen = suggestedKeys(id)
        var keys = Set<String>()
        let fresh = drafts.filter { !seen.contains($0.key) && keys.insert($0.key).inserted }
        let waiting = suggestions.filter { if case .automation(let other, _) = $0.origin { return other == id } else { return false } }.count
        let name = TaskSuggestion.Draft.clean(name, limit: 100, newlines: false)
        return store(fresh, origin: .automation(id: id, name: name.isEmpty ? id : name), limit: Self.maxPendingPerAutomation - waiting)
    }

    /// Stores what an agent proposed through `tasks_suggest`. It goes through the same path as a watcher's `suggest_task`, so the
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

    /// Stores the new tasks the task scan found. The title check also covers meeting action items that wait, so the same thing is
    /// not offered twice. Each draft's own `sourceRef` says which chat message, meeting or capture it came from.
    @discardableResult
    package func suggest(scan drafts: [TaskSuggestion.Draft]) -> [TaskSuggestion] {
        let waiting = suggestions.filter { $0.origin == .taskScan }.count
        return store(drafts, origin: .taskScan, limit: max(0, Self.maxPendingScan - waiting))
    }

    /// Stores the changes to existing tasks the task scan found. A change to a task that does not exist or is done, one that
    /// changes nothing, and one that repeats a waiting suggestion for the same task are left out.
    @discardableResult
    package func suggest(scanUpdates updates: [(update: TaskSuggestion.Update, sourceRef: String?)]) -> [TaskSuggestion] {
        let time = now()
        var added: [TaskSuggestion] = []
        var taken = Set(suggestions.map(\.id))
        var waiting = suggestions.filter { $0.origin == .taskScan }.count
        for (proposal, sourceRef) in updates where waiting < Self.maxPendingScan {
            guard let target = task(proposal.target), target.status != .done else { continue }
            var change = proposal
            change.targetTitle = target.title
            change.note = change.note.map { TaskSuggestion.Draft.clean($0, limit: Self.maxUpdateNote, newlines: false) }.flatMap { $0.isEmpty ? nil : $0 }
            change.waitingOn = change.waitingOn.flatMap { try? TaskValidator.waitingOn(String($0.prefix(TaskValidator.maxWaitingOn))) }
            if change.waitingOn == target.waitingOn { change.waitingOn = nil }
            guard !change.isEmpty else { continue }
            let same = { (other: TaskSuggestion) in
                other.update.map { $0.target == change.target && $0.note == change.note && $0.markDone == change.markDone && $0.waitingOn == change.waitingOn } ?? false
            }
            guard !suggestions.contains(where: same), !added.contains(where: same) else { continue }
            let id = AutomationValidator.slug("update \(target.title)", taken: taken)
            taken.insert(id)
            let ref: [String: Any] = ["ref": "task-scan", "reason": "Found by the task scan", "at": ISO8601DateFormatter().string(from: time)]
            added.append(TaskSuggestion(id: id, title: target.title, origin: .taskScan, created: time,
                                        sourceRef: sourceRef ?? Self.refText(ref), update: change))
            waiting += 1
        }
        guard !added.isEmpty else { return [] }
        do {
            try database.write { db in
                for s in added { try Self.insert(s, db) }
            }
        } catch {
            NSLog("ironpet: could not store task suggestions: \(error.localizedDescription)")
            return []
        }
        reload()
        didChange(nil)
        return added
    }

    private func store(_ drafts: [TaskSuggestion.Draft], origin: TaskSuggestion.Origin, limit: Int = .max,
                       sourceRef: String? = nil) -> [TaskSuggestion] {
        // Compared by `ActionItems.normalized`, so a regenerated summary that words an item with another case, spacing or
        // closing full stop does not offer it a second time.
        let existing = Set(tasks.map { ActionItems.normalized($0.title) } + suggestions.map { ActionItems.normalized($0.title) })
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
            case .taskScan:
                ref = ["ref": "task-scan", "reason": "Found by the task scan", "at": ISO8601DateFormatter().string(from: time)]
            }
            added.append((draft.key, TaskSuggestion(id: id, title: title, due: draft.due, notes: draft.notes, url: draft.url,
                                                    origin: origin, created: time, waitingOn: waitingOn,
                                                    sourceRef: sourceRef ?? draft.sourceRef ?? Self.refText(ref),
                                                    clarify: draft.clarify?.isEmpty == false ? draft.clarify : nil)))
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
            NSLog("ironpet: could not store task suggestions: \(error.localizedDescription)")
            return []
        }
        reload()
        didChange(nil)
        return added.map(\.suggestion)
    }

    /// The stored proposal, or nil when the row has none (every column empty).
    private static func clarify(context: String?, area: String?, twoMinute: Int64?, someday: Int64?) -> TaskSuggestion.Clarify? {
        guard twoMinute != nil || someday != nil || context != nil || area != nil else { return nil }
        let clarify = TaskSuggestion.Clarify(context: context.flatMap(TaskContext.init(rawValue:)), area: area,
                                             twoMinute: twoMinute == 1, someday: someday == 1)
        return clarify.isEmpty ? nil : clarify
    }

    private static func insert(_ s: TaskSuggestion, _ db: Database.Connection) throws {
        var meeting: String?, automation: String?, name: String?
        switch s.origin {
        case .meeting(let folder): meeting = folder.path
        case .automation(let id, let n): (automation, name) = (id, n)
        case .taskScan: break
        }
        try db.execute("""
            INSERT INTO task_suggestions(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref,
                                         scan, update_task, update_title, update_note, update_done, update_waiting,
                                         clarify_context, clarify_area, clarify_two_minute, clarify_someday)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [s.id, s.title, s.due, s.notes, s.url?.absoluteString, meeting, automation, name, s.created.timeIntervalSince1970,
                  s.waitingOn, s.sourceRef, s.origin == .taskScan ? 1 : 0, s.update?.target, s.update?.targetTitle, s.update?.note,
                  (s.update?.markDone ?? false) ? 1 : 0, s.update?.waitingOn,
                  s.clarify?.context?.rawValue, s.clarify?.area, s.clarify.map { $0.twoMinute ? 1 : 0 }, s.clarify.map { $0.someday ? 1 : 0 }])
    }

    private func suggestedKeys(_ automation: String) -> Set<String> {
        Set((try? database.read { db in
            try db.rows("SELECT key FROM task_suggestion_keys WHERE automation = ?", [automation]).compactMap { $0[0] as? String }
        }) ?? [])
    }

    /// What a reviewer may change before accepting. Nil fields keep the suggestion's own value.
    package struct Overrides {
        package init(title: String? = nil, due: String? = nil, notes: String? = nil, status: String? = nil) {
            self.title = title
            self.due = due
            self.notes = notes
            self.status = status
        }

        package var title: String?
        package var due: String?
        package var notes: String?
        package var status: String?
    }

    /// Turns a suggestion into a backlog task, linked to its meeting folder or to the url the automation gave, and waiting
    /// on the suggestion's owner if it has one. `note` goes to the new task's history.
    @discardableResult
    package func accept(_ suggestionID: String, overrides: Overrides = Overrides(), note: String? = nil, by: String = "user") throws -> TaskItem {
        guard let s = suggestions.first(where: { $0.id == suggestionID }) else { throw TaskError(message: "no suggestion \"\(suggestionID)\"") }
        let note = try note.map { try TaskValidator.notes($0) }
        if let change = s.update { return try apply(change, suggestion: s, note: note, by: by) }
        let due = try? TaskValidator.due(overrides.due ?? s.due)
        var notes = overrides.notes ?? s.notes
        var links: [TaskLink] = []
        if let folder = s.meeting {
            links.append(TaskLink(kind: .file, ref: folder.path, label: "Meeting"))
            if due == nil, let text = s.due { notes = "Due (from the meeting): \(text)" }
        }
        if let url = s.url { links.append(TaskLink(kind: .url, ref: url.absoluteString, label: nil)) }
        // The scan's clarify proposal is applied as filed: its labels, and someday instead of the backlog.
        let status = try overrides.status.map { try TaskValidator.status($0) } ?? (s.clarify?.someday == true ? .someday : .backlog)
        let labels = (try? TaskValidator.labels(s.clarify?.labels ?? [:])) ?? [:]
        var item = try create(title: overrides.title ?? s.title, notes: notes, status: status, source: s.source, due: due, links: links,
                              waitingOn: s.waitingOn, sourceRef: s.sourceRef, labels: labels, by: by)
        if let note, !note.isEmpty { item = try update(item.id, note: note, by: by) }
        removeSuggestion(suggestionID)
        return item
    }

    /// Applies an update suggestion to its target task: appends the note, marks it done, sets who it waits on. A task that is gone
    /// removes the suggestion and says so.
    private func apply(_ change: TaskSuggestion.Update, suggestion s: TaskSuggestion, note: String?, by: String) throws -> TaskItem {
        guard let target = task(change.target) else {
            removeSuggestion(s.id)
            throw TaskError(message: "the task \"\(change.targetTitle)\" no longer exists")
        }
        var notes: String?
        if let text = change.note, !text.isEmpty {
            let joined = target.notes.isEmpty ? text : target.notes + "\n\n" + text
            // A task whose notes are full keeps them as they are. The text still goes to its history.
            if joined.utf8.count <= TaskValidator.maxNotes { notes = joined }
        }
        let item = try update(change.target, notes: notes, status: change.markDone ? .done : nil,
                              waitingOn: change.waitingOn.map { Optional($0) }, note: note ?? change.note, by: by)
        removeSuggestion(s.id)
        return item
    }

    /// Adds every suggested new task. A change to an existing task is accepted on its own, never in bulk.
    package func acceptAll() {
        for s in suggestions where s.update == nil { _ = try? accept(s.id) }
    }

    /// Removes a suggestion.
    package func skip(_ suggestionID: String) {
        removeSuggestion(suggestionID)
    }

    /// `skip` with a reason, for a reviewer.
    package func reject(_ suggestionID: String, note: String? = nil, by: String) throws {
        guard suggestions.contains(where: { $0.id == suggestionID }) else { throw TaskError(message: "no suggestion \"\(suggestionID)\"") }
        _ = try note.map { try TaskValidator.notes($0) }
        skip(suggestionID)
    }

    // MARK: Due reminders

    /// Which tasks were announced as due, by id. Read from the database so a relaunch does not announce them again.
    package func dueMarks() -> [String: TaskDueMark] {
        let rows = (try? database.read { try $0.rows("SELECT task, due, snoozed_until FROM task_due_marks") }) ?? []
        var marks: [String: TaskDueMark] = [:]
        for row in rows {
            guard let task = row[0] as? String, let due = row[1] as? Double else { continue }
            marks[task] = TaskDueMark(due: Date(timeIntervalSince1970: due),
                                      snoozedUntil: (row[2] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        return marks
    }

    /// Records that these tasks were announced for their current due date, and when to announce them again (nil: never).
    package func markDue(_ items: [TaskItem], snoozedUntil: Date?) {
        let items = items.filter { $0.due != nil }
        guard !items.isEmpty else { return }
        do {
            try database.write { db in
                for item in items {
                    try db.execute("INSERT OR REPLACE INTO task_due_marks(task, due, snoozed_until) VALUES(?, ?, ?)",
                                   [item.id, item.due!.timeIntervalSince1970, snoozedUntil?.timeIntervalSince1970])
                }
            }
        } catch {
            NSLog("ironpet: could not store task reminders: \(error.localizedDescription)")
        }
    }

    // MARK: Task scan cursors

    /// What the task scan last read in one source (a chat id, a meeting folder, `screen`). Nil when it never read it.
    package func scanCursor(_ key: String) -> (item: String, at: Date)? {
        guard let row = (try? database.read { try $0.rows("SELECT item, at FROM task_scan_cursors WHERE key = ?", [key]) })?.first,
              let item = row[0] as? String else { return nil }
        return (item, Date(timeIntervalSince1970: row[1] as? Double ?? 0))
    }

    package func setScanCursors(_ cursors: [(key: String, item: String)]) {
        guard !cursors.isEmpty else { return }
        let time = now().timeIntervalSince1970
        try? database.write { db in
            for cursor in cursors {
                try db.execute("INSERT OR REPLACE INTO task_scan_cursors(key, item, at) VALUES(?, ?, ?)", [cursor.key, cursor.item, time])
            }
        }
    }

    private func removeSuggestion(_ id: String) {
        try? database.write { try $0.execute("DELETE FROM task_suggestions WHERE id = ?", [id]) }
        reload()
        didChange(nil)
    }

    // MARK: Storage

    /// Done tasks past `tasks.keepDoneDays`, and history of tasks that no longer exist, at launch and at most daily.
    package func prune() {
        let time = now()
        guard time.timeIntervalSince(lastPrune) > 86_400 else { return }
        lastPrune = time
        let cutoff = time.addingTimeInterval(-Double(keepDoneDays()) * 86_400).timeIntervalSince1970
        do {
            try database.write { db in
                try db.execute("DELETE FROM task_links WHERE task IN (SELECT id FROM task_items WHERE status = 'done' AND closed < ?)", [cutoff])
                try db.execute("DELETE FROM task_labels WHERE task IN (SELECT id FROM task_items WHERE status = 'done' AND closed < ?)", [cutoff])
                try db.execute("DELETE FROM task_items WHERE status = 'done' AND closed < ?", [cutoff])
                try db.execute("DELETE FROM task_due_marks WHERE task NOT IN (SELECT id FROM task_items)")
                try db.execute("DELETE FROM task_events WHERE at < ? AND task NOT IN (SELECT id FROM task_items)", [cutoff])
                try db.execute("DELETE FROM task_suggestion_keys WHERE at < ?",
                               [time.addingTimeInterval(-Double(Self.keepSuggestedKeysDays) * 86_400).timeIntervalSince1970])
            }
        } catch {
            NSLog("ironpet: could not prune tasks: \(error.localizedDescription)")
        }
    }

    /// Ids whose history is still kept, so a new task never inherits a deleted task's events.
    private func deletedIDs() -> Set<String> {
        Set((try? database.read { db in
            try db.rows("SELECT DISTINCT task FROM task_events").compactMap { $0[0] as? String }
        }) ?? [])
    }

    package func reload() {
        prune()
        do {
            let (items, suggested) = try database.read { db -> ([TaskItem], [TaskSuggestion]) in
                var links: [String: [TaskLink]] = [:]
                for row in try db.rows("SELECT task, kind, ref, label FROM task_links ORDER BY task, position") {
                    guard let task = row[0] as? String, let kind = (row[1] as? String).flatMap(TaskLink.Kind.init(rawValue:)),
                          let ref = row[2] as? String else { continue }
                    links[task, default: []].append(TaskLink(kind: kind, ref: ref, label: row[3] as? String))
                }
                var labels: [String: [String: String]] = [:]
                for row in try db.rows("SELECT task, key, value FROM task_labels") {
                    guard let task = row[0] as? String, let key = row[1] as? String, let value = row[2] as? String else { continue }
                    labels[task, default: [:]][key] = value
                }
                let items = try db.rows("SELECT id, title, notes, status, source, due, created, updated, closed, waiting_on, source_ref, defer_until FROM task_items").compactMap { row -> TaskItem? in
                    guard let id = row[0] as? String, let title = row[1] as? String,
                          let status = (row[3] as? String).flatMap(TaskStatus.init(rawValue:)),
                          let created = row[6] as? Double, let updated = row[7] as? Double else { return nil }
                    return TaskItem(id: id, title: title, notes: row[2] as? String ?? "", status: status,
                                    source: (row[4] as? String).flatMap(TaskSource.init(rawValue:)) ?? .agent,
                                    due: (row[5] as? Double).map(Date.init(timeIntervalSince1970:)), links: links[id] ?? [],
                                    created: Date(timeIntervalSince1970: created), updated: Date(timeIntervalSince1970: updated),
                                    closed: (row[8] as? Double).map(Date.init(timeIntervalSince1970:)), waitingOn: row[9] as? String,
                                    sourceRef: row[10] as? String, labels: labels[id] ?? [:],
                                    deferUntil: (row[11] as? Double).map(Date.init(timeIntervalSince1970:)))
                }
                let suggested = try db.rows("""
                    SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref,
                           scan, update_task, update_title, update_note, update_done, update_waiting,
                           clarify_context, clarify_area, clarify_two_minute, clarify_someday
                    FROM task_suggestions ORDER BY created, id
                    """).compactMap { row -> TaskSuggestion? in
                    guard let id = row[0] as? String, let title = row[1] as? String, let created = row[8] as? Double else { return nil }
                    let origin: TaskSuggestion.Origin
                    if let meeting = row[5] as? String {
                        origin = .meeting(URL(fileURLWithPath: meeting))
                    } else if let automation = row[6] as? String {
                        origin = .automation(id: automation, name: row[7] as? String ?? automation)
                    } else if (row[11] as? Int64 ?? 0) == 1 {
                        origin = .taskScan
                    } else {
                        return nil
                    }
                    var change: TaskSuggestion.Update?
                    if let target = row[12] as? String {
                        change = TaskSuggestion.Update(target: target, targetTitle: row[13] as? String ?? title, note: row[14] as? String,
                                                       markDone: (row[15] as? Int64 ?? 0) == 1, waitingOn: row[16] as? String)
                    }
                    return TaskSuggestion(id: id, title: title, due: row[2] as? String, notes: row[3] as? String ?? "",
                                          url: (row[4] as? String).flatMap(URL.init(string:)), origin: origin,
                                          created: Date(timeIntervalSince1970: created), waitingOn: row[9] as? String,
                                          sourceRef: row[10] as? String, update: change,
                                          clarify: Self.clarify(context: row[17] as? String, area: row[18] as? String,
                                                                twoMinute: row[19] as? Int64, someday: row[20] as? Int64))
                }
                return (items, suggested)
            }
            // Refs are written after the read, so the write never nests inside it.
            let refs = records.refs(.task, items.map(\.id))
            let withRefs = items.map { item -> TaskItem in
                var item = item
                item.ref = refs[item.id]
                return item
            }
            if withRefs != tasks { tasks = withRefs }
            if suggested != suggestions { suggestions = suggested }
        } catch {
            NSLog("ironpet: could not read tasks: \(error.localizedDescription)")
        }
    }

    private static func save(_ item: TaskItem, _ db: Database.Connection) throws {
        try db.execute("""
            INSERT OR REPLACE INTO task_items(id, title, notes, status, source, due, created, updated, closed, waiting_on, source_ref,
                                              defer_until, node_id, agent_id)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [item.id, item.title, item.notes, item.status.rawValue, item.source.rawValue, item.due?.timeIntervalSince1970,
                  item.created.timeIntervalSince1970, item.updated.timeIntervalSince1970, item.closed?.timeIntervalSince1970,
                  item.waitingOn, item.sourceRef, item.deferUntil?.timeIntervalSince1970] + Provenance.current(db).columns)
        try db.execute("DELETE FROM task_links WHERE task = ?", [item.id])
        for (position, link) in item.links.enumerated() {
            try db.execute("INSERT INTO task_links(task, position, kind, ref, label) VALUES(?, ?, ?, ?, ?)",
                           [item.id, position, link.kind.rawValue, link.ref, link.label])
        }
        try db.execute("DELETE FROM task_labels WHERE task = ?", [item.id])
        for (key, value) in item.labels {
            try db.execute("INSERT INTO task_labels(task, key, value) VALUES(?, ?, ?)", [item.id, key, value])
        }
    }

    private static func log(_ db: Database.Connection, _ task: String, _ at: Date, _ by: String, _ kind: TaskEvent.Kind, _ detail: String) throws {
        try db.execute("INSERT INTO task_events(task, at, by, kind, detail, node_id, agent_id) VALUES(?, ?, ?, ?, ?, ?, ?)",
                       [task, at.timeIntervalSince1970, by, kind.rawValue, detail] + Provenance.current(db).columns)
    }
}

#if canImport(Combine)

extension TaskStore: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
