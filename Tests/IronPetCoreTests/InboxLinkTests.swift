import XCTest
@testable import IronPetCore

/// The links an inbox item offers: the meeting it came from and the page a watcher or agent named.
final class InboxLinkTests: XCTestCase {
    private func item(origin: TaskSuggestion.Origin, url: URL? = nil) -> TaskSuggestion {
        TaskSuggestion(id: "i", title: "Send the deck", url: url, origin: origin, created: Date(timeIntervalSince1970: 0))
    }

    func testAMeetingItemLinksToItsMeetingFolder() {
        let links = item(origin: .meeting(URL(fileURLWithPath: "/tmp/meetings/2026-11-17-0930"))).links
        XCTAssertEqual(links, [TaskLink(kind: .meeting, ref: "2026-11-17-0930", label: "Meeting")])
    }

    func testAWatcherItemLinksToItsPage() {
        let page = URL(string: "https://example.com/pr/12")!
        let links = item(origin: .automation(id: "prs", name: "PRs"), url: page).links
        XCTAssertEqual(links, [TaskLink(kind: .url, ref: "https://example.com/pr/12")])
    }

    func testAnItemWithNoSourceHasNoLinks() {
        XCTAssertTrue(item(origin: .automation(id: "prs", name: "PRs")).links.isEmpty)
    }

    func testLinkHelpNamesWhatOpens() {
        XCTAssertEqual(TaskLink(kind: .url, ref: "https://github.com/you/app/pull/1").help, "Open github.com")
        XCTAssertEqual(TaskLink(kind: .url, ref: "https://x.dev", label: "PR #1").help, "Open PR #1")
        XCTAssertEqual(TaskLink(kind: .meeting, ref: "2026-11-17-0930", label: " ").help, "Open meeting")
    }

    func testOnlyWebLinksOpenInTheBrowser() {
        XCTAssertEqual(TaskLinkRow(link: TaskLink(kind: .url, ref: "https://x.dev")).action, .openURL(URL(string: "https://x.dev")!))
        XCTAssertEqual(TaskLinkRow(link: TaskLink(kind: .url, ref: "file:///etc/passwd")).action, .none)
        XCTAssertEqual(TaskLinkRow(link: TaskLink(kind: .meeting, ref: "2026-11-17-0930")).action, .openMeeting("2026-11-17-0930"))
    }

    func testTheOriginNamesTheSource() {
        XCTAssertEqual(item(origin: .meeting(URL(fileURLWithPath: "/m"))).originLabel, "Meeting")
        XCTAssertEqual(item(origin: .automation(id: "prs", name: "PRs")).originLabel, "From PRs")
    }
}
