import XCTest
@testable import IronPetKit

final class ChatMessageCollapseTests: XCTestCase {
    func testShortMessageIsNotCollapsed() {
        XCTAssertNil(ChatMessageCollapse.preview(of: "hello"))
        XCTAssertNil(ChatMessageCollapse.preview(of: String(repeating: "a", count: ChatMessageCollapse.maxCharacters)))
    }

    func testManyLinesCollapse() {
        let text = (0..<(ChatMessageCollapse.maxLines + 1)).map { "l\($0)" }.joined(separator: "\n")
        let preview = ChatMessageCollapse.preview(of: text)
        XCTAssertEqual(preview?.text.split(separator: "\n").count, ChatMessageCollapse.previewLines)
    }

    func testThirtyLinesStayExpanded() {
        let text = (0..<ChatMessageCollapse.maxLines).map { "l\($0)" }.joined(separator: "\n")
        XCTAssertNil(ChatMessageCollapse.preview(of: text))
    }

    func testLongTextCutsAtWordBoundary() throws {
        let text = String(repeating: "word ", count: 12_000)
        let preview = try XCTUnwrap(ChatMessageCollapse.preview(of: text))
        XCTAssertLessThanOrEqual(preview.text.count, ChatMessageCollapse.previewCharacters)
        XCTAssertTrue(preview.text.hasSuffix("word"))
        XCTAssertEqual(preview.hiddenCharacters, text.count - preview.text.count)
    }

    func testHiddenTextIsNotInPreview() throws {
        let text = String(repeating: "a", count: 2_000) + "SECRET"
        let preview = try XCTUnwrap(ChatMessageCollapse.preview(of: text))
        XCTAssertFalse(preview.text.contains("SECRET"))
        XCTAssertEqual(preview.text.count, ChatMessageCollapse.previewCharacters)
    }

    func testThirtyLinesWithTrailingNewlineStayExpanded() {
        let text = (0..<ChatMessageCollapse.maxLines).map { "l\($0)" }.joined(separator: "\n") + "\n"
        XCTAssertNil(ChatMessageCollapse.preview(of: text))
    }

    func testCRLFLinesCollapse() {
        let text = (0..<(ChatMessageCollapse.maxLines + 1)).map { "l\($0)" }.joined(separator: "\r\n")
        XCTAssertEqual(ChatMessageCollapse.preview(of: text)?.text.split(whereSeparator: \.isNewline).count, ChatMessageCollapse.previewLines)
    }
}
