import XCTest
@testable import IronPetKit

final class RemoteChatFindTests: XCTestCase {
    private let items: [RemoteChatItem] = [
        RemoteChatItem(id: "u1", kind: "user", text: "Please Deploy the app"),
        RemoteChatItem(id: "t1", kind: "tool", text: "Ran `deploy.sh`", ok: true),
        RemoteChatItem(id: "a1", kind: "assistant", text: "Done. **Deploy** finished, then DEPLOY again.\n\n- déploy check\n\n```\nnpm run deploy\n```"),
        RemoteChatItem(id: "s1", kind: "screenshot", fileName: "deploy.png"),
        RemoteChatItem(id: "e1", kind: "error", text: "deploy failed"),
        RemoteChatItem(id: "a2", kind: "assistant", text: "Nothing to see."),
    ]

    func testRangesIgnoreCaseAndDiacritics() {
        XCTAssertEqual(ChatFindText.ranges(of: "deploy", in: "Deploy, DEPLOY and déploy"), [0..<6, 8..<14, 19..<25])
        XCTAssertEqual(ChatFindText.ranges(of: "aa", in: "aaaa"), [0..<2, 2..<4])
        XCTAssertTrue(ChatFindText.ranges(of: "", in: "abc").isEmpty)
    }

    func testMatchesCoverWhatAPersonOrTheAgentWroteInReadingOrder() {
        let matches = RemoteChatFind.matches(query: "deploy", in: items)
        // user 1, assistant paragraph 2, list 1 and code 1. Tool steps, attachments and errors are not searched.
        XCTAssertEqual(matches.map(\.itemID), ["u1", "a1", "a1", "a1", "a1"])
        XCTAssertEqual(matches.map(\.segment), [0, 0, 0, 1, 2])
        XCTAssertEqual(matches.map(\.occurrence), [0, 0, 1, 0, 0])
    }

    func testMarkdownMarkersAreNotMatches() {
        let bold = [RemoteChatItem(id: "a", kind: "assistant", text: "**bold** and `code`")]
        XCTAssertTrue(RemoteChatFind.matches(query: "**", in: bold).isEmpty)
        XCTAssertEqual(RemoteChatFind.matches(query: "bold and code", in: bold).count, 1)
    }

    func testTableCellsAndTaskItemsAreSearched() {
        let text = "| Name | Role |\n|---|---|\n| Ada | Pilot |\n\n- [x] ship Pilot docs"
        let matches = RemoteChatFind.matches(query: "pilot", in: [RemoteChatItem(id: "a", kind: "assistant", text: text)])
        XCTAssertEqual(matches.count, 2)
        XCTAssertNotEqual(matches[0].segment, matches[1].segment)
    }

    func testNoQueryOrNoHitMeansNoMatches() {
        XCTAssertTrue(RemoteChatFind.matches(query: "", in: items).isEmpty)
        XCTAssertTrue(RemoteChatFind.matches(query: "zzz", in: items).isEmpty)
        XCTAssertEqual(ChatFindText.label(query: "zzz", count: 0, index: nil), "No results")
        XCTAssertEqual(ChatFindText.label(query: "", count: 0, index: nil), "")
        XCTAssertEqual(ChatFindText.label(query: "a", count: 12, index: 2), "3 of 12")
    }

    func testStepWrapsAtBothEnds() {
        XCTAssertEqual(ChatFindText.step(from: nil, count: 3, by: 1), 0)
        XCTAssertEqual(ChatFindText.step(from: nil, count: 3, by: -1), 2)
        XCTAssertEqual(ChatFindText.step(from: 2, count: 3, by: 1), 0)
        XCTAssertEqual(ChatFindText.step(from: 0, count: 3, by: -1), 2)
        XCTAssertNil(ChatFindText.step(from: 0, count: 0, by: 1))
    }

    func testTheCurrentMatchSurvivesNewContent() {
        var matches = RemoteChatFind.matches(query: "deploy", in: items)
        let current = matches[3]
        // A new reply after the matches changes nothing for the reader.
        matches = RemoteChatFind.matches(query: "deploy", in: items + [RemoteChatItem(id: "a3", kind: "assistant", text: "deploy ok")])
        XCTAssertEqual(ChatFindText.reconcile(current: current, in: matches), 3)
        // A match that vanished keeps the reader's place.
        XCTAssertEqual(ChatFindText.reconcile(current: RemoteChatFind.Match(itemID: "gone", segment: 0, occurrence: 0), previousIndex: 2, in: matches), 2)
        XCTAssertEqual(ChatFindText.reconcile(current: nil, in: matches), 0)
        XCTAssertNil(ChatFindText.reconcile(current: current, in: []))
    }

    func testOnlyRowsWithAMatchGetAHighlightAndOneHoldsTheCurrentMatch() {
        let matches = RemoteChatFind.matches(query: "deploy", in: items)
        let highlights = RemoteChatFind.highlights(query: "deploy", matches: matches, current: matches[2])
        XCTAssertEqual(Set(highlights.keys), ["u1", "a1"])
        XCTAssertNil(highlights["u1"]?.current)
        XCTAssertEqual(highlights["a1"]?.current, matches[2])
    }
}
