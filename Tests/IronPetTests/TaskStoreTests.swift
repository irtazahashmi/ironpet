import XCTest
@testable import IronPet
@testable import IronPetCore

/// The inbox store: meeting items, watcher items, agent items, and done and remove.
@MainActor
final class TaskStoreTests: XCTestCase {
    private var database: Database!
    private var store: TaskStore!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var changes = 0
    private let meeting = URL(fileURLWithPath: "/tmp/ironpet-meetings/2026-11-16 1000")

    override func setUp() async throws {
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        changes = 0
        store = makeStore()
    }

    override func tearDown() async throws {
        store = nil
        database = nil
    }

    private func makeStore() -> TaskStore {
        let store = TaskStore(database: database, now: { [unowned self] in clock })
        store.onChange = { [unowned self] in changes += 1 }
        return store
    }

    private func draft(_ key: String, _ title: String, url: URL? = nil) -> TaskSuggestion.Draft {
        TaskSuggestion.Draft(key: key, title: title, url: url)
    }

    // MARK: Meeting items

    func testMeetingItemsSkipDuplicatesAndSurviveARestart() {
        let added = store.suggest([("Book the room", "2026-11-20", nil), ("book the room", nil, nil), ("Email Sam", "next Tuesday", nil),
                                   ("   ", nil, nil)], meeting: meeting)
        XCTAssertEqual(added.map(\.title), ["Book the room", "Email Sam"])
        XCTAssertEqual(added.map(\.id), ["book-the-room", "email-sam"])
        XCTAssertEqual(store.suggestions, added)
        XCTAssertEqual(store.suggestions.first?.meeting, meeting)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.suggest([("BOOK THE ROOM", nil, nil), ("Order lunch", nil, nil)], meeting: meeting).map(\.title), ["Order lunch"])
        XCTAssertEqual(store.suggest([("Order lunch", nil, nil)], meeting: meeting), [])
        XCTAssertEqual(makeStore().suggestions, store.suggestions, "items survive a restart")
    }

    func testAMeetingItemKeepsWhenItArrived() throws {
        clock = Date(timeIntervalSince1970: 1_800_000_500)
        let added = store.suggest([("Send the deck", nil, nil)], meeting: meeting)
        XCTAssertEqual(added.first?.created, clock)
        XCTAssertEqual(makeStore().suggestions.first?.created, clock)
    }

    // MARK: Done and remove

    func testDoneAndRemoveTakeItemsOffTheList() throws {
        store.suggest([("One", nil, nil), ("Two", nil, nil), ("Three", nil, nil)], meeting: meeting)
        changes = 0
        try store.done("two")
        XCTAssertEqual(store.suggestions.map(\.id), ["one", "three"])
        try store.remove("one", note: "wrong")
        XCTAssertEqual(store.suggestions.map(\.id), ["three"])
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(makeStore().suggestions.map(\.id), ["three"], "the removal is stored")
    }

    func testDoneAndRemoveOfAnUnknownItemThrowAndChangeNothing() {
        store.suggest([("One", nil, nil)], meeting: meeting)
        changes = 0
        XCTAssertThrowsError(try store.done("nope")) { XCTAssertEqual(($0 as? TaskError)?.message, "no inbox item \"nope\"") }
        XCTAssertThrowsError(try store.remove("nope"))
        XCTAssertThrowsError(try store.remove("one", note: String(repeating: "x", count: 5000)), "the note is checked")
        XCTAssertEqual(store.suggestions.map(\.id), ["one"])
        XCTAssertEqual(changes, 0)
    }

    // MARK: Watcher items

    func testDraftCleansAndClampsWatcherText() throws {
        let d = try TaskSuggestion.Draft(action: [
            "type": "suggest_task", "id": 42, "title": "  Reply\u{0007} to\n\tSam\u{202E}gnp.exe  ",
            "notes": "Line one\r\nLine two\u{0000}" + String(repeating: "x", count: 3000),
            "due": "2026-11-20", "url": "https://mail.example.com/m/1",
        ])
        XCTAssertEqual(d.key, "42")
        XCTAssertEqual(d.title, "Reply to Samgnp.exe")
        XCTAssertTrue(d.notes.hasPrefix("Line one \nLine two" + "xxx"), d.notes)
        XCTAssertEqual(d.notes.count, TaskSuggestion.Draft.maxNotes)
        XCTAssertEqual(d.due, "2026-11-20")
        XCTAssertEqual(d.url?.absoluteString, "https://mail.example.com/m/1")

        let long = try TaskSuggestion.Draft(action: ["id": "a", "title": String(repeating: "t", count: 500),
                                                     "notes": String(repeating: "é", count: 3000), "due": "next Friday",
                                                     "url": "javascript:alert(1)"])
        XCTAssertEqual(long.title.count, TaskSuggestion.Draft.maxTitle)
        XCTAssertLessThanOrEqual(long.notes.utf8.count, TaskValidator.maxNotes)
        XCTAssertNil(long.due, "only yyyy-MM-dd")
        XCTAssertNil(long.url, "only http and https")
        XCTAssertNil(try TaskSuggestion.Draft(action: ["id": "b", "title": "x", "url": "file:///etc/passwd", "due": "2026-11-20T10:00:00Z"]).url)
        XCTAssertThrowsError(try TaskSuggestion.Draft(action: ["title": "no id"]))
        XCTAssertThrowsError(try TaskSuggestion.Draft(action: ["id": "c", "title": " \u{0001}\n "]))
    }

    func testAWatcherItemIsNotRepeatedAfterDoneOrRemove() throws {
        let added = store.suggest([draft("m1", "Reply to Sam"), draft("m1", "Reply to Sam again"), draft("m2", "Book flights")],
                                  automation: "gmail", name: "Gmail\nwatcher")
        XCTAssertEqual(added.map(\.title), ["Reply to Sam", "Book flights"], "the same key counts once per call")
        XCTAssertEqual(added.first?.origin, .automation(id: "gmail", name: "Gmail watcher"))
        XCTAssertEqual(added.first?.originLabel, "From Gmail watcher")

        XCTAssertEqual(store.suggest([draft("m1", "Reply to Sam")], automation: "gmail", name: "Gmail"), [], "already waiting")
        try store.remove("reply-to-sam")
        try store.done("book-flights")
        XCTAssertEqual(store.suggest([draft("m1", "Reply to Sam"), draft("m2", "Book flights, renamed")], automation: "gmail", name: "Gmail"), [],
                       "removed and done keys stay remembered")
        XCTAssertEqual(makeStore().suggest([draft("m1", "Reply to Sam")], automation: "gmail", name: "Gmail"), [], "also after a restart")
        XCTAssertEqual(store.suggest([draft("m1", "Reply to Sam")], automation: "slack", name: "Slack").map(\.title), ["Reply to Sam"],
                       "keys belong to one automation")
    }

    func testWatcherItemsWaitingAreCapped() throws {
        let many = (1...60).map { draft("k\($0)", "Item \($0)") }
        XCTAssertEqual(store.suggest(many, automation: "w", name: "W").count, TaskStore.maxPendingPerAutomation)
        XCTAssertEqual(store.suggest([draft("k60", "Item 60")], automation: "w", name: "W"), [], "no room")
        try store.done("item-1")
        XCTAssertEqual(store.suggest([draft("k60", "Item 60")], automation: "w", name: "W").map(\.title), ["Item 60"],
                       "a capped one was not remembered, so it comes when there is room")
    }

    func testAWatcherItemKeepsItsLinkAndNotes() {
        let url = URL(string: "https://github.com/acme/app/issues/9")!
        var d = draft("9", "Triage issue 9", url: url)
        d.due = "2026-11-20"
        d.notes = "Opened by a customer"
        store.suggest([d], automation: "gh", name: "GitHub")
        let item = store.suggestions[0]
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.notes, "Opened by a customer")
        XCTAssertEqual(item.due, "2026-11-20")
        XCTAssertEqual(item.links, [TaskLink(kind: .url, ref: url.absoluteString)])
        XCTAssertEqual(item.source, .automation)
        XCTAssertEqual(TaskSource.automation.symbol, "clock.badge.checkmark")
    }

    // MARK: Agent items

    func testAgentItemsShareTheWatcherPathAndDedupePerOriginKind() throws {
        let origin: [String: Any] = ["kind": "email", "ref": "mail:1", "reason": "Ana asked"]
        func add(_ args: [String: Any], origin: [String: Any]? = nil) throws {
            var args = args
            args["origin"] = origin ?? ["kind": "email", "ref": "mail:1", "reason": "Ana asked"]
            if case .failure(let error) = TaskJSON.call(TasksAPI(store: store), "add", args, by: "agent:cli") { throw error }
        }
        _ = origin
        let long = String(repeating: "x", count: 300)
        try add(["id": "mail:1", "title": long + "\u{0007}", "notes": String(repeating: "n", count: 3000), "due": "soon", "url": "ftp://x"])
        let first = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(first.title.count, 200)
        XCTAssertEqual(first.notes.count, 2000)
        XCTAssertNil(first.due)
        XCTAssertNil(first.url)
        XCTAssertEqual(first.origin, .automation(id: "agent:email", name: "email agent"))
        XCTAssertTrue(try XCTUnwrap(first.sourceRef).contains("Ana asked"))

        try add(["id": "mail:1", "title": "Different"])
        XCTAssertEqual(store.suggestions.count, 1, "same id")
        XCTAssertEqual(store.suggestions.first?.title, "Different", "the same id while the item is in the inbox updates it")
        try store.remove(first.id)
        try add(["id": "mail:1", "title": long])
        XCTAssertEqual(store.suggestions.count, 0, "same id after a removal")
        try add(["id": "mail:1", "title": "Other kind"], origin: ["kind": "pr", "ref": "r", "reason": "x"])
        XCTAssertEqual(store.suggestions.count, 1, "ids are kept per origin kind")
        XCTAssertThrowsError(try add(["title": "No id"]))
        XCTAssertThrowsError(try add(["id": "z"]))
    }

    // MARK: Order and migrations

    func testItemsAreOldestFirst() {
        store.suggest([("First", nil, nil)], meeting: meeting)
        clock = clock.addingTimeInterval(60)
        store.suggest([draft("k", "Second")], automation: "gh", name: "GitHub")
        XCTAssertEqual(store.suggestions.map(\.title), ["First", "Second"])
    }

    func testNoTwoMigrationsShareAVersionAndTheNewOneComesAfterEveryOldOne() {
        let versions = AppMigrations.all.map(\.version)
        XCTAssertEqual(versions.count, Set(versions).count)
        XCTAssertEqual(TaskStore.migrations.map(\.version).max(), 593)
        XCTAssertEqual(AppMigrations.latestVersion, 603)
    }

    // MARK: Migration 590 (S1)

    func testUpgradingADatabaseWithTasksDropsThemAndKeepsTheInbox() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-590-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ironpet.db")

        let before = try Database(path: file, migrations: AppMigrations.all.filter { $0.version <= 583 })
        XCTAssertEqual(before.schemaVersion, 583)
        try before.write { db in
            try db.execute("INSERT INTO task_items(id, title, notes, status, source, created, updated) VALUES('old-task', 'Old', '', 'backlog', 'chat', 1, 1)")
            try db.execute("INSERT INTO task_events(task, at, by, kind, detail) VALUES('old-task', 1, 'chat', 'created', 'backlog: Old')")
            try db.execute("INSERT INTO task_suggestions(id, title, meeting, created) VALUES('from-meeting', 'Send the deck', '/m/2026-11-16 1000', 5)")
            try db.execute("INSERT INTO task_suggestions(id, title, automation, automation_name, created) VALUES('from-watcher', 'Reply to Sam', 'gmail', 'Gmail', 6)")
            try db.execute("INSERT INTO task_suggestions(id, title, meeting, created, waiting_on) VALUES('waits', 'Ana sends the contract', '/m/2026-11-16 1000', 8, 'Ana')")
            try db.execute("INSERT INTO task_suggestions(id, title, automation, automation_name, created, update_task) VALUES('change', 'Close the old one', 'task-scan', 'Task scan', 7, 'old-task')")
            try db.execute("INSERT INTO record_refs(ref, kind, key) VALUES('task_9f3c1e', 'task', 'old-task'), ('filter_1a2b3c', 'filter', 'mine'), ('job_aaaaaa', 'job', 'fix')")
        }

        let after = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(after.schemaVersion, AppMigrations.latestVersion)
        let tables = try after.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table'") }.compactMap { $0[0] as? String }
        for gone in ["task_items", "task_links", "task_events", "task_labels", "task_due_marks", "task_scan_cursors", "task_projects", "task_areas", "task_goals", "task_key_results"] {
            XCTAssertFalse(tables.contains(gone), "\(gone) is still there")
        }
        let refs = try after.read { try $0.rows("SELECT kind FROM record_refs ORDER BY kind") }.compactMap { $0[0] as? String }
        XCTAssertEqual(refs, ["job"], "the ids of tasks and filters are gone")

        let reopened = TaskStore(database: after)
        XCTAssertEqual(reopened.suggestions.map(\.id), ["from-meeting", "from-watcher"], "a proposed change to a task and an item waiting on someone go with the tasks")
        XCTAssertEqual(reopened.suggestions.first?.meeting, URL(fileURLWithPath: "/m/2026-11-16 1000"))
        XCTAssertEqual(reopened.suggestions.last?.origin, .automation(id: "gmail", name: "Gmail"))
        try reopened.done("from-meeting")
        XCTAssertEqual(reopened.suggestions.map(\.id), ["from-watcher"])
        XCTAssertEqual(try Database(path: file, migrations: AppMigrations.all).schemaVersion, AppMigrations.latestVersion, "a second start changes nothing")
    }

    func testAFreshDatabaseHasNoTaskTables() throws {
        let tables = try database.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'task%'") }.compactMap { $0[0] as? String }
        XCTAssertEqual(Set(tables), ["task_suggestions", "task_suggestion_keys", "task_suggestion_sources", "task_suggestion_resolved", "task_suggestion_notes"])
    }
}
