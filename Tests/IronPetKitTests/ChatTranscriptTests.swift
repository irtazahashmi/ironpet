import XCTest
@testable import IronPetKit

/// The phone's transcript logic. The markdown and collapse cases are the Mac's own tests (`MarkdownTests`, `MessageCollapseTests`)
/// run against the phone's copy, so the two cannot drift apart without a test noticing.
final class ChatTranscriptTests: XCTestCase {
    // MARK: Markdown

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
        XCTAssertEqual(ChatMarkdown.parse("```mermaid\ngraph TD\nA-->B"), [
            .code(language: "mermaid", text: "graph TD\nA-->B", closed: false),
        ])
    }

    func testTasksQuotesAndTables() {
        let blocks = ChatMarkdown.parse("- [ ] open\n- [x] done\n\n> quoted\n> twice\n\n| A | B |\n|---|---|\n| 1 |")
        XCTAssertEqual(blocks.count, 3)
        guard case .list(_, let items) = blocks[0] else { return XCTFail("a list") }
        XCTAssertEqual(items[0].task?.done, false)
        XCTAssertEqual(items[1].task?.text, "done")
        XCTAssertEqual(blocks[1], .quote("quoted\ntwice"))
        XCTAssertEqual(blocks[2], .table(header: ["A", "B"], rows: [["1", ""]]))
    }

    func testInlineMarkdownKeepsBoldCodeAndLinks() {
        let text = ChatMarkdown.inline("**bold** `code` [site](https://example.com)")
        XCTAssertEqual(String(text.characters), "bold code site")
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(text.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    // MARK: Collapse

    func testShortMessageIsNotCollapsed() {
        XCTAssertNil(ChatMessageCollapse.preview(of: "hello"))
        XCTAssertNil(ChatMessageCollapse.preview(of: String(repeating: "a", count: ChatMessageCollapse.maxCharacters)))
    }

    func testManyLinesCollapse() {
        let text = (0..<(ChatMessageCollapse.maxLines + 1)).map { "l\($0)" }.joined(separator: "\n")
        XCTAssertEqual(ChatMessageCollapse.preview(of: text)?.text.split(separator: "\n").count, ChatMessageCollapse.previewLines)
    }

    func testThirtyLinesStayExpanded() {
        let text = (0..<ChatMessageCollapse.maxLines).map { "l\($0)" }.joined(separator: "\n")
        XCTAssertNil(ChatMessageCollapse.preview(of: text))
        XCTAssertNil(ChatMessageCollapse.preview(of: text + "\n"))
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

    func testCRLFLinesCollapse() {
        let text = (0..<(ChatMessageCollapse.maxLines + 1)).map { "l\($0)" }.joined(separator: "\r\n")
        XCTAssertEqual(ChatMessageCollapse.preview(of: text)?.text.split(whereSeparator: \.isNewline).count, ChatMessageCollapse.previewLines)
    }

    // MARK: Tool steps

    private func tool(_ id: String, _ text: String, ok: Bool?) -> RemoteChatItem { RemoteChatItem(id: id, kind: "tool", text: text, ok: ok) }

    func testConsecutiveToolsGroupAndOthersStayAlone() {
        let items = [RemoteChatItem(id: "u", kind: "user", text: "go"), tool("t1", "Ran `ls`", ok: true), tool("t2", "Read a.swift", ok: true),
                     RemoteChatItem(id: "a", kind: "assistant", text: "done"), tool("t3", "Ran `pwd`", ok: nil)]
        let groups = RemoteTranscriptGroup.make(items)
        XCTAssertEqual(groups.map(\.id), ["u", "t1", "a", "t3"])
        guard case .tools(let steps) = groups[1] else { return XCTFail("a run of tools") }
        XCTAssertEqual(steps.map(\.id), ["t1", "t2"])
    }

    func testTheHeaderCountsStepsByKind() {
        let steps = [tool("1", "Ran `a`", ok: true), tool("2", "Ran `b`", ok: true), tool("3", "Read x", ok: true), tool("4", "Edited y", ok: true)]
        XCTAssertEqual(ChatToolSteps.header(steps, expanded: false), "Ran 2 commands, read 1 file, edited 1 file")
        XCTAssertEqual(ChatToolSteps.state(steps), .done)
    }

    func testTheHeaderShowsTheStepInFlightUntilExpanded() {
        let steps = [tool("1", "Ran `a`", ok: true), tool("2", "Ran `b`", ok: nil)]
        XCTAssertEqual(ChatToolSteps.header(steps, expanded: false), "Ran `b`")
        XCTAssertEqual(ChatToolSteps.header(steps, expanded: true), "Ran 2 commands")
        XCTAssertEqual(ChatToolSteps.state(steps), .running)
        XCTAssertEqual(ChatToolSteps.state([tool("1", "Ran `a`", ok: false)]), .failed)
    }

    // MARK: Notices and wire

    func testANoticeSplitsIntoLabelAndDetail() {
        let notice = ChatNotice("Automation ran\nChecked 3 PRs.\n\nAll green.")
        XCTAssertEqual(notice.label, "Automation ran")
        XCTAssertEqual(notice.detail, "Checked 3 PRs.\n\nAll green.")
        XCTAssertEqual(ChatNotice("Only a label").detail, "")
    }

    func testANoticeItemAndTheRunStartDecode() throws {
        let json = """
        {"title":"t","state":"running","running":true,"run_started":"2026-01-01T10:00:00Z","folder_label":"demo","agent":{"id":"claude","name":"Claude Code"},
         "items":[{"id":"n","kind":"notice","text":"Automation ran\\nDetail"}],"approvals":[],"forms":[],"queue":[]}
        """
        let snapshot = try WireJSON.makeDecoder().decode(RemoteChatSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.items.first?.row, .notice("Automation ran\nDetail"))
        XCTAssertEqual(snapshot.runStarted, ISO8601DateFormatter().date(from: "2026-01-01T10:00:00Z"))
    }

    // MARK: Following the end

    func testGrowthWhilePinnedKeepsFollowingAndAReaderScrollingUpStops() {
        var follow = TranscriptFollowState()
        follow.measure(contentHeight: 1000, viewportHeight: 600, distanceFromBottom: 0)
        // The content grew and the end moved away: not the reader's doing.
        follow.measure(contentHeight: 1100, viewportHeight: 600, distanceFromBottom: 100)
        XCTAssertTrue(follow.pinned)
        // Nothing grew and the distance did: the reader scrolled up.
        follow.measure(contentHeight: 1100, viewportHeight: 600, distanceFromBottom: 300)
        XCTAssertFalse(follow.pinned)
    }

    func testAReaderAwayFromTheEndSeesNewContentAsAJumpButtonAndStaysPut() {
        var follow = TranscriptFollowState()
        follow.measure(contentHeight: 1000, viewportHeight: 600, distanceFromBottom: 0)
        follow.measure(contentHeight: 1000, viewportHeight: 600, distanceFromBottom: 300, userDriven: true)
        follow.contentArrived(readerSent: false)
        XCTAssertFalse(follow.pinned)
        XCTAssertTrue(follow.newBelow)
        follow.jumpedToLatest()
        XCTAssertTrue(follow.pinned)
        XCTAssertFalse(follow.newBelow)
    }

    func testSendingAMessageFollowsFromThere() {
        var follow = TranscriptFollowState()
        follow.measure(contentHeight: 1000, viewportHeight: 600, distanceFromBottom: 300, userDriven: true)
        follow.contentArrived(readerSent: true)
        XCTAssertTrue(follow.pinned)
        XCTAssertFalse(follow.newBelow)
    }

    func testTheKeyboardShrinkingTheViewportDoesNotUnpin() {
        var follow = TranscriptFollowState()
        follow.measure(contentHeight: 1000, viewportHeight: 600, distanceFromBottom: 0)
        follow.measure(contentHeight: 1000, viewportHeight: 300, distanceFromBottom: 300)
        XCTAssertTrue(follow.pinned)
    }
}
