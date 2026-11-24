import AppKit
import XCTest
@testable import IronPet
@testable import IronPetCore
@testable import IronPetKit

@MainActor
final class SelectionProbeTests: XCTestCase {
    private func view(_ markdown: String) -> ChatTextView {
        let view = ChatTextView.make()
        view.setContent(MarkdownText.attributed(ChatMarkdown.parse(markdown), size: 13.5, find: nil))
        view.frame = CGRect(origin: .zero, size: view.fittingSize(forWidth: 300))
        return view
    }

    func testReadsTheSelectionWithoutTouchingThePasteboard() {
        let view = view("Intro\n\n- one\n- two")
        let board = NSPasteboard.general
        board.clearContents()
        board.setString("kept", forType: .string)
        let count = board.changeCount
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertEqual(SelectionProbe.selectedText(in: view), "Intro\n- one\n- two")
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "kept")
    }

    func testEmptySelectionIsNil() {
        let view = view("Some text")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(SelectionProbe.selectedText(in: view))
    }

    func testWhitespaceOnlySelectionIsNil() {
        let view = view("a\n\nb")
        view.setSelectedRange(NSRange(location: 1, length: 1))
        XCTAssertNil(SelectionProbe.selectedText(in: view))
    }
}

@MainActor
final class SelectionAnchorTests: XCTestCase {
    private func window(with view: ChatTextView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        view.setContent(MarkdownText.attributed(ChatMarkdown.parse("First paragraph\n\n- one\n- two"), size: 13.5, find: nil))
        view.frame = CGRect(origin: .zero, size: view.fittingSize(forWidth: 300))
        window.contentView?.addSubview(view)
        return window
    }

    func testAnchorNamesTheMessageForAnyRange() {
        let view = ChatTextView.make()
        let id = UUID()
        view.messageID = id
        let window = window(with: view)
        let total = view.string.utf16.count
        // Word, paragraph and a range across list items, as double-click, triple-click and shift-extend produce.
        for range in [NSRange(location: 0, length: 5), NSRange(location: 0, length: 15), NSRange(location: 3, length: total - 3)] {
            view.setSelectedRange(range)
            XCTAssertEqual(SelectionProbe.anchor(for: view)?.id, id, "\(range)")
        }
        _ = window
    }

    func testAnchorIsNilWhenTheSelectionIsCleared() {
        let view = ChatTextView.make()
        view.messageID = UUID()
        let window = window(with: view)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertNotNil(SelectionProbe.anchor(for: view))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNil(SelectionProbe.anchor(for: view))
        _ = window
    }

    func testAnchorFollowsTheNewSelectionInAnotherMessage() {
        let first = ChatTextView.make(), second = ChatTextView.make()
        let a = UUID(), b = UUID()
        first.messageID = a
        second.messageID = b
        let win = window(with: first)
        _ = window(with: second)
        first.setSelectedRange(NSRange(location: 0, length: 5))
        second.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(SelectionProbe.anchor(for: first)?.id, a)
        XCTAssertEqual(SelectionProbe.anchor(for: second)?.id, b)
        _ = win
    }

    func testAnchorIsNilWithoutAMessage() {
        let view = ChatTextView.make()
        let window = window(with: view)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertNil(SelectionProbe.anchor(for: view))
        _ = window
    }

    func testAnchorIsNilWhenTheSelectionIsScrolledOutOfView() {
        let view = ChatTextView.make()
        view.messageID = UUID()
        let window = window(with: view)
        // Clip the view to its first lines, as a scroll view does, then select text below them.
        let clip = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 10))
        window.contentView?.addSubview(clip)
        clip.addSubview(view)
        view.frame.origin = CGPoint(x: 0, y: -(view.frame.height - 10))
        let total = view.string.utf16.count
        view.setSelectedRange(NSRange(location: total - 3, length: 3))
        XCTAssertNil(SelectionProbe.anchor(for: view))
        _ = window
    }

    func testResolveAnchorNamesTheReasonItSkips() {
        let view = ChatTextView.make()
        let window = window(with: view)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(skip(SelectionProbe.resolveAnchor(for: view)), .noMessageID)
        view.messageID = UUID()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(skip(SelectionProbe.resolveAnchor(for: view)), .emptySelection)
        view.removeFromSuperview()
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(skip(SelectionProbe.resolveAnchor(for: view)), .noWindow)
        _ = window
    }

    private func skip(_ result: Result<(id: UUID, point: CGPoint), SelectionProbe.Skip>) -> SelectionProbe.Skip? {
        if case .failure(let reason) = result { return reason }
        return nil
    }
}
