import XCTest
@testable import IronPetKit

final class InboxPresentationTests: XCTestCase {
    private struct Row: Equatable {
        var id: String
        var kind: String
        var created: Double
    }

    private func group(_ rows: [Row]) -> [InboxGroup<Row>] {
        InboxGrouping.group(rows, kind: \.kind, created: { Date(timeIntervalSince1970: $0.created) }, tie: \.id)
    }

    /// S5: origin groups with counts, newest first inside a group, and the group with the newest item on top.
    func testGroupsOrderByTheirNewestItemAndEachGroupIsNewestFirst() {
        let groups = group([Row(id: "a", kind: "meeting", created: 10), Row(id: "b", kind: "chat", created: 30), Row(id: "c", kind: "chat", created: 20),
                            Row(id: "d", kind: "capture", created: 40), Row(id: "e", kind: "meeting", created: 5)])
        XCTAssertEqual(groups.map(\.kind), ["capture", "chat", "meeting"])
        XCTAssertEqual(groups.map(\.title), ["Screen capture", "Chat", "Meeting"])
        XCTAssertEqual(groups.map(\.items.count), [1, 2, 2])
        XCTAssertEqual(groups[1].items.map(\.id), ["b", "c"])
        XCTAssertEqual(groups[2].items.map(\.id), ["a", "e"])
    }

    func testItemsWithTheSameTimeKeepAStableOrder() {
        XCTAssertEqual(group([Row(id: "a", kind: "chat", created: 1), Row(id: "b", kind: "chat", created: 1)])[0].items.map(\.id), ["b", "a"])
    }

    func testOtherSourcesAreNamedOnceAndNotTheFirst() {
        XCTAssertNil(InboxGrouping.otherSources([]))
        XCTAssertNil(InboxGrouping.otherSources(["Chat"]))
        XCTAssertNil(InboxGrouping.otherSources(["Chat", "Chat"]))
        XCTAssertEqual(InboxGrouping.otherSources(["Chat", "Agent"]), "and Agent")
        XCTAssertEqual(InboxGrouping.otherSources(["Chat", "Agent", "Email", "Agent"]), "and Agent, Email")
    }

    /// S7: the origin line is the stored reason with the chat as a link. It has no raw id in it.
    func testTheOriginLineLinksTheWordChat() {
        let line = InboxOriginLine.make(reason: "Found by the inbox scan in a chat between the user and Bunny", kind: "chat", chatThread: "T-1")
        XCTAssertEqual(line.segments, [.text("Found by the inbox scan in a "), .chat(thread: "T-1"), .text(" between the user and Bunny")])
        XCTAssertEqual(line.plain(time: "27 Nov, 15:04"), "Found by the inbox scan in a chat between the user and Bunny, 27 Nov, 15:04")
        XCTAssertFalse(line.plain(time: "x").contains("T-1"))
    }

    func testAReasonThatNeverSaysChatGetsTheLinkAfterIt() {
        let line = InboxOriginLine.make(reason: "Asked to be reminded", kind: "chat", chatThread: "T-1")
        XCTAssertEqual(line.segments, [.text("Asked to be reminded in a "), .chat(thread: "T-1")])
    }

    func testChatInsideAnotherWordIsNotTheLink() {
        let line = InboxOriginLine.make(reason: "Chatty review of the chatbot", kind: "chat", chatThread: "T-1")
        XCTAssertEqual(line.segments.count, 2)
        XCTAssertEqual(line.segments.last, .chat(thread: "T-1"))
    }

    func testNoReasonSaysFromAAndTheKind() {
        XCTAssertEqual(InboxOriginLine.make(reason: nil, kind: "chat", chatThread: nil).plain(time: "12:54"), "From a chat, 12:54")
        XCTAssertEqual(InboxOriginLine.make(reason: "  ", kind: "capture", chatThread: nil).plain(time: "t"), "From a screen capture, t")
        XCTAssertEqual(InboxOriginLine.make(reason: nil, kind: "chat", chatThread: "T-9").segments, [.text("From a "), .chat(thread: "T-9")])
    }

    /// S8: the link on the word chat carries the thread id and the page reads it back.
    func testTheChatLinkRoundTripsTheThreadId() throws {
        let id = "7B2F-ä/ ?x=1&y"
        let url = try XCTUnwrap(InboxChatLink.url(thread: id))
        XCTAssertEqual(InboxChatLink.thread(from: url), id)
        XCTAssertNil(InboxChatLink.thread(from: URL(string: "https://example.com/?thread=x")!))
        let text = InboxChatLink.text(InboxOriginLine.make(reason: "From a chat", kind: "chat", chatThread: id), time: "t")
        XCTAssertEqual(String(text.characters), "From a chat, t")
        XCTAssertEqual(text.runs.compactMap(\.link).compactMap(InboxChatLink.thread(from:)), [id])
    }

    func testChatRefsNameAThreadOnlyWhenTheyHaveAnId() {
        XCTAssertEqual(InboxGrouping.chatThread(ref: "chat:abc"), "abc")
        XCTAssertNil(InboxGrouping.chatThread(ref: "chat:"))
        XCTAssertNil(InboxGrouping.chatThread(ref: "capture:12"))
    }

    func testSourceRowsLinkChatsPagesAndMeetingsAndHideBareIds() {
        let rows = InboxSourceRow.rows([
            .init(kind: "chat", ref: "chat:abc", url: nil, label: "Chat"),
            .init(kind: "agent", ref: "x", url: "https://example.atlassian.net/browse/SSP-1?x=1", label: "Agent"),
            .init(kind: "meeting", ref: "/Users/me/.ironpet/meetings/2026-11-16-1000", url: nil, label: "Meeting"),
            .init(kind: "capture", ref: "capture:12", url: nil, label: nil),
            .init(kind: "agent", ref: "y", url: "file:///etc/passwd", label: "Agent"),
        ])
        XCTAssertEqual(rows[0].action, .showChat(thread: "abc"))
        XCTAssertEqual(rows[0].actionTitle, "Show chat")
        XCTAssertEqual(rows[1].action, .openURL(URL(string: "https://example.atlassian.net/browse/SSP-1?x=1")!))
        XCTAssertEqual(rows[1].actionTitle, "example.atlassian.net/browse/SSP-1")
        XCTAssertEqual(rows[2].action, .openMeeting(folder: "2026-11-16-1000"))
        XCTAssertEqual(rows[3].title, "Screen capture")
        XCTAssertEqual(rows[3].action, .none)
        XCTAssertNil(rows[3].actionTitle, "a capture id on its own is not shown")
        XCTAssertEqual(rows[4].action, .none, "only http and https open")
    }

    func testThePhoneSideOfAnItemUsesTheSameLogic() {
        let item = RemoteSuggestion(id: "s", title: "Test", origin: "automation", url: "https://x.dev/1",
                                    sourceRef: .object(["ref": .string("chat:T-2"), "reason": .string("Found by the inbox scan in a chat between the user and Bunny")]),
                                    sources: [RemoteSource(kind: "chat", ref: "chat:T-2", label: "Chat"), RemoteSource(kind: "agent", ref: "r", label: "Agent")])
        XCTAssertEqual(item.groupKind, "chat")
        XCTAssertEqual(item.chatThread, "T-2")
        XCTAssertEqual(item.originLine.segments.count, 3)
        XCTAssertEqual(item.otherSourcesLabel, "and Agent")
        XCTAssertEqual(item.openURL?.absoluteString, "https://x.dev/1")
        XCTAssertNil(RemoteSuggestion(id: "p", title: "Plain").openURL)
        XCTAssertEqual(RemoteSuggestion(id: "m", title: "Old Mac", origin: "meeting").groupKind, "meeting")
        XCTAssertEqual(RemoteSuggestion(id: "o", title: "Old Mac", origin: "task-scan").groupKind, "automation")
        XCTAssertEqual(RemoteSuggestion(id: "o", title: "Old Mac", origin: "automation", url: "https://x.dev/2").sourceRows.first?.actionTitle, "x.dev/2")
    }
}
