import XCTest
@testable import IronPetKit

final class RecordLinksTests: XCTestCase {
    private func ids(in text: String) -> [String] { RecordLinks.detect(in: text).map(\.id) }

    func testFindsIdsInASentence() {
        XCTAssertEqual(ids(in: "See task_9f3c1e and meeting_abc123."), ["task_9f3c1e", "meeting_abc123"])
        XCTAssertEqual(ids(in: "It is task_9f3c1e."), ["task_9f3c1e"], "a full stop after an id is not part of it")
    }

    func testLeavesPathsFileNamesAndNearMissesAlone() {
        XCTAssertEqual(ids(in: "/Users/me/task_9f3c1e/notes.md"), [], "inside a path")
        XCTAssertEqual(ids(in: "notes.task_9f3c1e.md"), [], "inside a file name")
        XCTAssertEqual(ids(in: "old_task_9f3c1e"), [], "inside a word")
        XCTAssertEqual(ids(in: "task_9f3c1 is too short"), [], "five digits")
        XCTAssertEqual(ids(in: "task_9F3C1E is uppercase"), [], "uppercase")
        XCTAssertEqual(ids(in: "pair_9f3c1e is not a kind"), [], "an unknown prefix")
    }

    func testAnIdBecomesAnIronPetLinkAndBack() throws {
        let url = try XCTUnwrap(RecordLinks.url(for: "task_9f3c1e"))
        XCTAssertEqual(url.absoluteString, "ironpet://task_9f3c1e")
        XCTAssertEqual(RecordLinks.id(from: url), "task_9f3c1e")
    }

    func testOtherLinksAreNotRecordLinks() throws {
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "ironpet://pair?u=https://192.168.1.2:8443&c=abc"))), "the pairing link")
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "ironpet://task_xyz"))), "not a valid id")
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "https://example.com/task_9f3c1e"))), "another scheme")
        XCTAssertNil(RecordLinks.id(from: try XCTUnwrap(URL(string: "ironpet://task_9f3c1e?x=1"))), "a query")
    }

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
}
