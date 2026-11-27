import IronPetKit
import XCTest
@testable import IronPetCore

/// What the Inbox screens say about an item, from its stored fields only.
@MainActor
final class InboxPresentationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, _ title: String, ageMinutes: Double, kind: TaskSource = .chat, url: String? = nil, reason: String? = nil,
                      sources: [InboxSource]? = nil) -> TaskSuggestion {
        let ref = TaskStore.refText(["ref": "chat:t-\(id)", "reason": reason ?? "Found by the inbox scan in a chat between the user and Bunny"])
        return TaskSuggestion(id: id, title: title, url: url.flatMap(URL.init(string:)), origin: .automation(id: "agent:\(kind.rawValue)", name: "x"),
                              created: base.addingTimeInterval(-ageMinutes * 60), sourceRef: ref,
                              sources: sources ?? [InboxSource(kind: kind, ref: kind == .chat ? "chat:t-\(id)" : "capture:1", label: InboxSource.displayName(kind))])
    }

    /// S5: three origin groups with counts, newest first.
    func testItemsFromChatMeetingAndScreenFormThreeGroupsNewestFirst() async {
        let meeting = TaskSuggestion(id: "m", title: "Send the notes", origin: .meeting(URL(fileURLWithPath: "/tmp/m/1")), created: base.addingTimeInterval(-3000))
        let groups = TaskSuggestion.groups([item("a", "Old chat item", ageMinutes: 300), meeting, item("c", "Screen item", ageMinutes: 9, kind: .capture),
                                            item("b", "New chat item", ageMinutes: 6)])
        XCTAssertEqual(groups.map(\.title), ["Chat", "Screen capture", "Meeting"], "the group with the newest item is first")
        XCTAssertEqual(groups.map(\.items.count), [2, 1, 1])
        XCTAssertEqual(groups[0].items.map(\.title), ["New chat item", "Old chat item"])
        XCTAssertEqual(groups.map(\.symbol), ["bubble.left", "text.viewfinder", SharedSymbols.meetings])
    }

    /// S6: only an item with a url has Open, and Open is that url.
    func testOnlyAnItemWithAUrlHasAnOpenButton() async {
        XCTAssertEqual(item("a", "With link", ageMinutes: 1, url: "https://x.dev/1").openURL?.absoluteString, "https://x.dev/1")
        XCTAssertNil(item("b", "No link", ageMinutes: 1).openURL)
        XCTAssertNil(item("c", "File link", ageMinutes: 1, url: "file:///etc/hosts").openURL)
    }

    func testTheRowNamesTheOtherSources() async {
        let merged = item("a", "Merged", ageMinutes: 1, sources: [InboxSource(kind: .chat, ref: "chat:t-a", label: "Chat"),
                                                                   InboxSource(kind: .agent, ref: "r", url: URL(string: "https://x.dev/1"), label: "Agent")])
        XCTAssertEqual(merged.otherSourcesLabel, "and Agent")
        XCTAssertNil(item("b", "Single", ageMinutes: 1).otherSourcesLabel)
    }

    /// S7: the origin line is the stored reason with the chat as a link. The page shows no id, and Notes come before Sources.
    func testTheOriginLineOfAScanItemLinksItsChat() async throws {
        let scanned = item("a", "Test the flow", ageMinutes: 5)
        XCTAssertEqual(scanned.chatThread, "t-a")
        XCTAssertEqual(scanned.originLine.segments, [.text("Found by the inbox scan in a "), .chat(thread: "t-a"), .text(" between the user and Bunny")])
        let rows = scanned.sourceRows
        XCTAssertEqual(rows.map(\.title), ["Chat"])
        XCTAssertEqual(rows.first?.action, .showChat(thread: "t-a"))
        let shown = (rows.compactMap(\.actionTitle) + [scanned.originLine.plain(time: "15:04")]).joined(separator: " ")
        XCTAssertFalse(shown.contains("chat:"), "no raw reference on the page")
        XCTAssertFalse(shown.contains(scanned.id + "-"), shown)
    }

    func testAnItemWithoutAStoredReasonSaysWhereItCameFrom() async {
        let bare = TaskSuggestion(id: "m", title: "Send", origin: .meeting(URL(fileURLWithPath: "/tmp/m/1")), created: base)
        XCTAssertEqual(bare.originLine.plain(time: "t"), "From a meeting, t")
        XCTAssertNil(bare.chatThread)
    }

    /// S9: a resolved item reads "Resolved by <who> at <time>", with its evidence under it.
    func testAResolvedItemSaysWhoResolvedItAndShowsTheReason() async {
        let record = ResolvedSuggestion(id: "a", title: "Answer the prompt", reason: "PR 398 merged", resolved: base, created: base.addingTimeInterval(-3600),
                                        sources: [InboxSource(kind: .chat, ref: "chat:t-1", label: "Chat")], resolvedBy: "Inbox scan")
        XCTAssertEqual(record.statusLine(time: "16:31"), "Resolved by Inbox scan at 16:31")
        XCTAssertEqual(record.originLine.plain(time: "12:54"), "From a chat, 12:54")
        XCTAssertEqual(record.originLine.segments, [.text("From a "), .chat(thread: "t-1")])
        XCTAssertEqual(record.sourceRows.first?.actionTitle, "Show chat")
    }

    /// The Resolved today section lists what was resolved since local midnight.
    func testResolvedTodayHoldsOnlyTodaysItems() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, now: { clock })
        let api = TasksAPI(store: store)
        store.suggest([(title: "Old", due: nil, waitingOn: nil), (title: "New", due: nil, waitingOn: nil)], meeting: URL(fileURLWithPath: "/tmp/m"))
        let calendar = Calendar.current
        let old = try XCTUnwrap(store.suggestions.first { $0.title == "Old" })
        clock = calendar.startOfDay(for: clock).addingTimeInterval(-3600)
        try store.resolve(old.id, reason: "yesterday", by: "Inbox scan")
        clock = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(60)
        let new = try XCTUnwrap(store.suggestions.first)
        try store.resolve(new.id, reason: "today", by: "Mail check")
        let today = api.resolvedToday(now: clock, calendar: calendar)
        XCTAssertEqual(today.map(\.reason), ["today"])
        XCTAssertEqual(today.first?.resolvedBy, "Mail check")
    }
}
