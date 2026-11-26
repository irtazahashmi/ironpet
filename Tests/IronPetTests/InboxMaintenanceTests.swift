import XCTest
@testable import IronPet
@testable import IronPetCore

/// The Inbox keeps itself short: the same thing from two sources is one item, a settled item leaves with its reason, a follow-up
/// changes the item it is about, and an item the user dealt with does not come back.
@MainActor
final class InboxMaintenanceTests: XCTestCase {
    private var database: Database!
    private var store: TaskStore!
    private var api: TasksAPI!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let meeting = URL(fileURLWithPath: "/tmp/ironpet-meetings/2026-11-16 1000")

    override func setUp() async throws {
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        store = TaskStore(database: database, now: { [unowned self] in clock })
        api = TasksAPI(store: store)
    }

    override func tearDown() async throws {
        api = nil
        store = nil
        database = nil
    }

    @discardableResult
    private func call(_ op: String, _ args: [String: Any]) -> Result<Any, TaskError> {
        TaskJSON.call(api, op, args, by: "agent:test")
    }

    private func add(_ id: String, _ title: String, kind: String = "email", ref: String = "mail", extra: [String: Any] = [:]) -> [String: Any] {
        var args: [String: Any] = ["id": id, "title": title, "origin": ["kind": kind, "ref": ref, "reason": "test"]]
        args.merge(extra) { _, new in new }
        guard case .success(let value) = call("add", args), let object = value as? [String: Any] else { return ["error": true] }
        return object
    }

    private func listed() -> [[String: Any]] {
        guard case .success(let value) = call("list", [:]) else { return [] }
        return (value as? [String: Any])?["items"] as? [[String: Any]] ?? []
    }

    private func meetingItem() throws -> TaskSuggestion {
        store.suggest([("Send the deck to Sam", "Friday", nil)], meeting: meeting)
        return try XCTUnwrap(store.suggestions.first)
    }

    // MARK: S1, one item for the same thing from two sources

    func testAMailNamingAMeetingItemJoinsItAndBothSourcesAreLinked() throws {
        let item = try meetingItem()
        XCTAssertEqual(item.sources.map(\.kind), [.meeting])
        let result = add("mail-1", "Sam asks for the deck", extra: ["same_as": item.id, "url": "https://mail.example.com/1"])
        XCTAssertEqual(result["merged"] as? Bool, true)

        let items = listed()
        XCTAssertEqual(items.count, 1, "no second item")
        let sources = try XCTUnwrap(items.first?["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.map { $0["kind"] as? String }, ["meeting", "email"])
        XCTAssertEqual(sources.last?["url"] as? String, "https://mail.example.com/1")
        XCTAssertEqual(items.first?["title"] as? String, "Send the deck to Sam", "a merge keeps the title the user saw")

        let merged = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(merged.links, [TaskLink(kind: .meeting, ref: "2026-11-16 1000", label: "Meeting"),
                                      TaskLink(kind: .url, ref: "https://mail.example.com/1", label: "Email")], "a link for each source")
        XCTAssertEqual(merged.fromLabel, "From Meeting and Email")
    }

    func testTheSameUrlMergesWithoutNamingTheItem() throws {
        add("pr-1", "Review the PR", kind: "pr", ref: "pr 1", extra: ["url": "https://github.com/a/b/pull/1"])
        let result = add("mail-2", "Ana asks for a review", extra: ["url": "https://github.com/a/b/pull/1/#files"])
        XCTAssertEqual(result["merged"] as? Bool, true)
        XCTAssertEqual(store.suggestions.count, 1)
        XCTAssertEqual(store.suggestions.first?.sources.map(\.kind), [.pr, .email], "the item says it came from both")
    }

    func testAnIdThatNamesNothingAddsNothing() {
        let result = add("mail-3", "Reply to Bo", extra: ["same_as": "no-such-item"])
        XCTAssertEqual(result["added"] as? Bool, false)
        XCTAssertTrue(store.suggestions.isEmpty, "a wrong same_as never becomes a second item")
    }

    func testTheAgentsOwnIdNamesTheItemToo() throws {
        add("mail-1", "Reply to Sam", ref: "mail 1")
        add("cal-1", "Sam's call", kind: "chat", ref: "event 1", extra: ["same_as": "mail-1"])
        XCTAssertEqual(store.suggestions.count, 1)
        XCTAssertEqual(store.suggestions.first?.sources.count, 2)
    }

    func testAMergedItemKeepsItsOneUrlAndItsNotes() throws {
        let item = try meetingItem()
        add("mail-1", "x", ref: "mail 1", extra: ["same_as": item.id, "url": "https://mail.example.com/1", "notes": "From the mail"])
        let merged = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(merged.notes, "From the mail", "an item with no notes takes them")
        add("mail-2", "y", ref: "mail 2", extra: ["same_as": item.id, "url": "https://mail.example.com/2", "notes": "Second mail"])
        XCTAssertEqual(store.suggestions.first?.notes, "From the mail", "notes that are there stay")
        XCTAssertEqual(store.suggestions.first?.sources.count, 3)
    }

    // MARK: S2, a settled item leaves with its reason

    func testResolveTakesTheItemOffAndKeepsTheReason() throws {
        add("mail-1", "Reply to Sam")
        XCTAssertEqual(listed().count, 1)
        let id = try XCTUnwrap(store.suggestions.first?.id)

        guard case .success(let value) = call("resolve", ["id": id, "reason": "answered"]),
              let resolved = (value as? [String: Any])?["resolved"] as? [String: Any] else { return XCTFail("resolve failed") }
        XCTAssertEqual(resolved["reason"] as? String, "answered")
        XCTAssertTrue(listed().isEmpty)

        guard case .success(let after) = call("list", ["include_resolved": true]), let result = after as? [String: Any] else { return XCTFail() }
        XCTAssertEqual((result["items"] as? [Any])?.count, 0)
        let records = try XCTUnwrap(result["resolved"] as? [[String: Any]])
        XCTAssertEqual(records.first?["reason"] as? String, "answered")
        XCTAssertEqual(records.first?["title"] as? String, "Reply to Sam")
        XCTAssertNotNil(records.first?["resolved"])
        guard case .success(let plain) = call("list", [:]) else { return XCTFail() }
        XCTAssertNil((plain as? [String: Any])?["resolved"], "resolved items are listed only on request")
    }

    func testResolveByTheIdTheAgentAddedItUnder() {
        add("mail-1", "Reply to Sam")
        guard case .success = call("resolve", ["id": "mail-1", "reason": "answered"]) else { return XCTFail("resolve by the agent's id failed") }
        XCTAssertTrue(store.suggestions.isEmpty)
        XCTAssertEqual(store.resolved().map(\.reason), ["answered"])
    }

    func testResolveNeedsAnItemAndAReason() throws {
        add("mail-1", "Reply to Sam")
        let id = try XCTUnwrap(store.suggestions.first?.id)
        guard case .failure(let noReason) = call("resolve", ["id": id, "reason": "  "]) else { return XCTFail() }
        XCTAssertTrue(noReason.message.contains("reason"))
        guard case .failure(let missing) = call("resolve", ["id": "ghost", "reason": "answered"]) else { return XCTFail() }
        XCTAssertTrue(missing.message.contains("no inbox item"))
        XCTAssertEqual(store.suggestions.count, 1, "a refused resolve changes nothing")
        XCTAssertTrue(store.resolved().isEmpty)
    }

    func testAReasonIsCleanedAndCapped() throws {
        add("mail-1", "Reply to Sam")
        let id = try XCTUnwrap(store.suggestions.first?.id)
        call("resolve", ["id": id, "reason": "answered\u{0007}\nby Sam " + String(repeating: "x", count: 300)])
        let reason = try XCTUnwrap(store.resolved().first?.reason)
        XCTAssertEqual(reason.count, 200)
        XCTAssertFalse(reason.contains("\n"))
        XCTAssertFalse(reason.contains("\u{0007}"))
    }

    // MARK: S3, a follow-up changes the item

    func testTheSameIdWithANewDueDateUpdatesTheItem() throws {
        add("mail-1", "Send the report", extra: ["due": "2026-12-01", "notes": "First mail"])
        let id = try XCTUnwrap(store.suggestions.first?.id)
        let result = add("mail-1", "Send the report", extra: ["due": "2026-12-08"])
        XCTAssertEqual(result["updated"] as? Bool, true)
        XCTAssertEqual(store.suggestions.count, 1)
        XCTAssertEqual(store.suggestions.first?.id, id)
        XCTAssertEqual(store.suggestions.first?.due, "2026-12-08")
        XCTAssertEqual(store.suggestions.first?.notes, "First mail", "text the follow-up leaves out stays")
        XCTAssertEqual(store.suggestions.first?.sources.count, 1, "the same mail is not listed twice")
    }

    func testAnUpdateTakesTheNewTitleNotesAndUrl() throws {
        add("mail-1", "Send the report", extra: ["url": "https://mail.example.com/1"])
        add("mail-1", "Send the final report", extra: ["notes": "Now final", "url": "https://mail.example.com/1b"])
        let item = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(store.suggestions.count, 1)
        XCTAssertEqual(item.title, "Send the final report")
        XCTAssertEqual(item.notes, "Now final")
        XCTAssertEqual(item.url?.absoluteString, "https://mail.example.com/1b")
        XCTAssertEqual(item.sources.compactMap { $0.url?.absoluteString }, ["https://mail.example.com/1b"], "the same mail has one link")
    }

    func testNamingTheItemWithANewDueDateChangesTheDate() throws {
        let item = try meetingItem()
        add("mail-1", "Sam moved it", extra: ["same_as": item.id, "due": "2026-12-08"])
        XCTAssertEqual(store.suggestions.count, 1)
        XCTAssertEqual(store.suggestions.first?.due, "2026-12-08")
    }

    func testAWatcherKeyUpdatesItsItem() throws {
        let draft = { (due: String?) in TaskSuggestion.Draft(key: "mail-1", title: "Reply to Sam", due: due, url: URL(string: "https://x/1")) }
        store.suggest([draft("2026-12-01")], automation: "gmail", name: "Gmail")
        let added = try XCTUnwrap(store.suggestions.first)
        let added2 = store.suggest([draft("2026-12-09")], automation: "gmail", name: "Gmail")
        XCTAssertTrue(added2.isEmpty, "an update is not a new item, so it gets no bubble")
        XCTAssertEqual(store.suggestions.map(\.id), [added.id])
        XCTAssertEqual(store.suggestions.first?.due, "2026-12-09")
    }

    func testAnUpdateSurvivesARestart() throws {
        add("mail-1", "Send the report", extra: ["due": "2026-12-01"])
        add("mail-1", "Send the report", extra: ["due": "2026-12-08"])
        let reopened = TaskStore(database: database, now: { [unowned self] in clock })
        XCTAssertEqual(reopened.suggestions.first?.due, "2026-12-08")
        XCTAssertEqual(reopened.suggestions.count, 1)
    }

    // MARK: S4, what the user dealt with stays gone

    func testARemovedItemDoesNotComeBackAsAnUpdateOrAMerge() throws {
        let item = try meetingItem()
        add("mail-1", "Reply to Sam", extra: ["same_as": item.id, "url": "https://mail.example.com/1"])
        try store.remove(item.id)
        XCTAssertTrue(store.suggestions.isEmpty)

        XCTAssertEqual(add("mail-1", "Reply to Sam", extra: ["due": "2026-12-08"])["added"] as? Bool, false, "the id of a merge is ignored")
        XCTAssertEqual(add("mail-1", "Reply to Sam", extra: ["same_as": item.id])["added"] as? Bool, false)
        XCTAssertEqual(add("mail-2", "Other mail", extra: ["same_as": item.id])["added"] as? Bool, false, "naming a removed item adds nothing")
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testAResolvedItemDoesNotComeBack() throws {
        add("mail-1", "Reply to Sam", extra: ["due": "2026-12-01"])
        let id = try XCTUnwrap(store.suggestions.first?.id)
        try store.resolve(id, reason: "answered")
        add("mail-1", "Reply to Sam", extra: ["due": "2026-12-08"])
        add("mail-1", "A new title", extra: ["same_as": id])
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testAnOldKeyDoesNotTouchALaterItemThatGotTheSameId() throws {
        add("mail-1", "Send the report")
        let first = try XCTUnwrap(store.suggestions.first)
        try store.done(first.id)
        // A new item with the same title gets the same slug.
        add("mail-2", "Send the report")
        let second = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(second.id, first.id)
        add("mail-1", "Changed", extra: ["due": "2026-12-08"])
        XCTAssertEqual(store.suggestions.first?.title, "Send the report")
        XCTAssertNil(store.suggestions.first?.due, "the first mail's old id does not change the new item")
    }

    func testAMeetingItemDoneStaysDoneForTheTitleRule() throws {
        let item = try meetingItem()
        try store.resolve(item.id, reason: "answered")
        XCTAssertEqual(store.resolved().first?.sources.first?.kind, .meeting)
    }

    // MARK: Migration 591

    func testMigration591GivesEveryExistingRowItsOneSourceAndKeepsTheKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-591-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ironpet.db")

        let before = try Database(path: file, migrations: AppMigrations.all.filter { $0.version <= 590 })
        XCTAssertEqual(before.schemaVersion, 590)
        try before.write { db in
            try db.execute("INSERT INTO task_suggestions(id, title, meeting, created) VALUES('from-meeting', 'Send the deck', '/m/2026-11-16 1000', 5)")
            try db.execute("INSERT INTO task_suggestions(id, title, url, automation, automation_name, created) VALUES('from-watcher', 'Reply to Sam', 'https://x/1', 'gmail', 'Gmail', 6)")
            try db.execute("INSERT INTO task_suggestion_keys(automation, key, at) VALUES('gmail', 'mail-1', \(Date().timeIntervalSince1970))")
        }

        let after = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(after.schemaVersion, AppMigrations.latestVersion)
        let reopened = TaskStore(database: after)
        XCTAssertEqual(reopened.suggestions.map(\.id), ["from-meeting", "from-watcher"])
        XCTAssertEqual(reopened.suggestions[0].sources, [InboxSource(kind: .meeting, ref: "/m/2026-11-16 1000", label: "Meeting")])
        XCTAssertEqual(reopened.suggestions[1].sources,
                       [InboxSource(kind: .automation, ref: "gmail", url: URL(string: "https://x/1"), label: "Gmail")])
        XCTAssertEqual(reopened.suggestions[1].links, [TaskLink(kind: .url, ref: "https://x/1")], "an old watcher item keeps its one unnamed link")

        // A key from before the migration does not know its item, so it is ignored as it was.
        let again = reopened.suggest([TaskSuggestion.Draft(key: "mail-1", title: "Reply to Sam (changed)")], automation: "gmail", name: "Gmail")
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(reopened.suggestions.map(\.title), ["Send the deck", "Reply to Sam"])
        XCTAssertEqual(try Database(path: file, migrations: AppMigrations.all).schemaVersion, AppMigrations.latestVersion, "a second start changes nothing")
    }

    func testAnOlderBuildRefusesTheNewDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-591-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ironpet.db")
        _ = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertThrowsError(try Database(path: file, migrations: AppMigrations.all.filter { $0.version <= 590 }))
    }

    // MARK: Limits and validation

    func testSourcesTextStaysValidated() {
        let result = add("mail-1", "Reply\u{0007} to Sam", extra: ["url": "javascript:alert(1)", "same_as": String(repeating: "z", count: 500)])
        XCTAssertEqual(result["added"] as? Bool, false, "an overlong same_as is cut and then names nothing")
        add("mail-2", "Reply to Bo", extra: ["url": "ftp://x/1"])
        XCTAssertNil(store.suggestions.first?.url)
        XCTAssertNil(store.suggestions.first?.sources.first?.url, "a source never keeps a non-web link")
    }

    func testItemsAreNotMergedByATitleOnlyMatch() {
        add("mail-1", "Reply to Sam")
        let result = add("mail-2", "Reply to Sam")
        XCTAssertEqual(result["added"] as? Bool, false, "the existing title rule still stops a plain duplicate")
        XCTAssertEqual(store.suggestions.first?.sources.count, 1, "and it does not merge on a guess")
    }
}
