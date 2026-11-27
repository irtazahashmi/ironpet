import IronPetCore
import IronPetKit
import XCTest
@testable import IronPet

@MainActor
final class InboxViewTests: XCTestCase {
    /// S8: the chat link on the item page carries the thread id, and clicking it asks the window to open that thread.
    func testTheChatLinkOpensTheItemsThread() throws {
        let item = TaskSuggestion(id: "a", title: "Test the flow", origin: .automation(id: "agent:chat", name: "chat agent"),
                                  created: Date(timeIntervalSince1970: 1_800_000_000),
                                  sourceRef: TaskStore.refText(["ref": "chat:thread-7", "reason": "Found by the inbox scan in a chat between the user and Bunny"]),
                                  sources: [InboxSource(kind: .chat, ref: "chat:thread-7", label: "Chat")])
        let text = InboxChatLink.text(item.originLine, time: InboxTime.arrived(item.created))
        let link = try XCTUnwrap(text.runs.compactMap(\.link).first)
        XCTAssertEqual(InboxChatLink.thread(from: link), "thread-7")
        XCTAssertEqual(item.sourceRows.first?.action, .showChat(thread: "thread-7"))
    }

    func testNavigationKeysSeparateOpenAndResolvedItemsThatShareAnId() {
        let open = TaskSuggestion(id: "a", title: "A", origin: .meeting(URL(fileURLWithPath: "/tmp/m")), created: Date())
        let record = ResolvedSuggestion(id: "a", title: "A", reason: "r", resolved: Date(), created: Date())
        XCTAssertNotEqual(InboxView.openKey(open), InboxView.resolvedKey(record))
    }
}
