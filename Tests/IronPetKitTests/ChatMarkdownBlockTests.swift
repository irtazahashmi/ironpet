import XCTest
@testable import IronPetKit

final class ChatMarkdownBlockTests: XCTestCase {
    func testHeadingsParagraphsAndRules() {
        XCTAssertEqual(ChatMarkdown.parse("# Title\n\nFirst line\nsecond line\n\n---\n## Next ##"), [
            .heading(level: 1, text: "Title"),
            .paragraph("First line\nsecond line"),
            .rule,
            .heading(level: 2, text: "Next"),
        ])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(ChatMarkdown.parse("#hashtag"), [.paragraph("#hashtag")])
    }

    func testListsKeepIndentAndContinuationLines() {
        let blocks = ChatMarkdown.parse("- one\n  still one\n  - nested\n- two\n\n1. first\n2) second")
        XCTAssertEqual(blocks, [
            .list(ordered: false, items: [
                .init(indent: 0, marker: "-", text: "one still one"),
                .init(indent: 1, marker: "-", text: "nested"),
                .init(indent: 0, marker: "-", text: "two"),
            ]),
            .list(ordered: true, items: [
                .init(indent: 0, marker: "1.", text: "first"),
                .init(indent: 0, marker: "2.", text: "second"),
            ]),
        ])
    }

    func testCodeFencesKeepContentAndReportUnclosedBlocks() {
        XCTAssertEqual(ChatMarkdown.parse("```swift\nlet a = 1\n\n# not a heading\n```\nafter"), [
            .code(language: "swift", text: "let a = 1\n\n# not a heading", closed: true),
            .paragraph("after"),
        ])
        // While a reply streams, the fence is still open; a diagram must not render yet.
        XCTAssertEqual(ChatMarkdown.parse("```mermaid\ngraph TD\nA-->B"), [
            .code(language: "mermaid", text: "graph TD\nA-->B", closed: false),
        ])
    }

    func testTablesPadShortRowsAndDropExtraCells() {
        XCTAssertEqual(ChatMarkdown.parse("| A | B |\n|---|:-:|\n| 1 |\n| 2 | 3 | 4 |"), [
            .table(header: ["A", "B"], rows: [["1", ""], ["2", "3"]]),
        ])
    }

    func testPipeWithoutSeparatorIsAParagraph() {
        XCTAssertEqual(ChatMarkdown.parse("a | b"), [.paragraph("a | b")])
    }

    func testQuotes() {
        XCTAssertEqual(ChatMarkdown.parse("> line one\n>line two\nplain"), [
            .quote("line one\nline two"),
            .paragraph("plain"),
        ])
    }
}
