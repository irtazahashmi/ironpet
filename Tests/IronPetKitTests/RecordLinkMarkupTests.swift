#if canImport(Darwin)
import XCTest
@testable import IronPetKit

/// The link step needs `AttributedString`'s Markdown attributes, so it runs on Apple platforms only.
final class RecordLinkMarkupTests: XCTestCase {
    func testLinksSkipCodeAndExistingLinks() throws {
        let text = try AttributedString(markdown: "see `task_9f3c1e` and task_abc123 with [a link](https://example.com)")
        let linked = RecordLinks.link(text)
        let links = linked.runs.compactMap { run -> String? in
            guard run.link != nil else { return nil }
            return String(linked[run.range].characters)
        }
        XCTAssertEqual(links, ["task_abc123", "a link"], "the id is linked, the code is not, and the existing link keeps its own target")
    }

    func testLinkKeepsTheText() throws {
        let text = try AttributedString(markdown: "Done: task_9f3c1e.")
        XCTAssertEqual(String(RecordLinks.link(text).characters), "Done: task_9f3c1e.")
    }

    func testChatTextLinksItsIds() throws {
        let inline = ChatMarkdown.inline("Opened meeting_abc123 for you.")
        let links = inline.runs.compactMap { $0.link }
        XCTAssertEqual(links, [try XCTUnwrap(RecordLinks.url(for: "meeting_abc123"))])
        XCTAssertEqual(String(inline.characters), "Opened meeting_abc123 for you.", "the text itself does not change")
    }
}
#endif
