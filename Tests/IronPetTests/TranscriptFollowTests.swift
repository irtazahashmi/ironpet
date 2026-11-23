import AppKit
import SwiftUI
import XCTest
@testable import IronPet
@testable import IronPetCore
@testable import IronPetKit

/// Pure rules for when the transcript follows new content.
final class TranscriptFollowLogicTests: XCTestCase {
    func testStartsPinned() {
        XCTAssertTrue(TranscriptFollowState().pinned)
    }

    func testUserScrollingAwayUnpins() {
        var f = TranscriptFollowState()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        XCTAssertFalse(f.pinned)
    }

    func testContentGrowthWithoutUserInputKeepsUnpinned() {
        var f = TranscriptFollowState()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.geometryChanged(distanceFromBottom: 900, userDriven: false)
        XCTAssertFalse(f.pinned)
    }

    func testContentGrowthWhilePinnedDoesNotUnpin() {
        var f = TranscriptFollowState()
        f.geometryChanged(distanceFromBottom: 300, userDriven: false)
        XCTAssertTrue(f.pinned)
    }

    func testUserScrollingBackToBottomPins() {
        var f = TranscriptFollowState()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.geometryChanged(distanceFromBottom: 5, userDriven: true)
        XCTAssertTrue(f.pinned)
    }

    func testArrivingAtBottomWithoutInputPins() {
        var f = TranscriptFollowState()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.geometryChanged(distanceFromBottom: 0, userDriven: false)
        XCTAssertTrue(f.pinned)
    }

    func testSendingAndJumpingPin() {
        var f = TranscriptFollowState()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.sent()
        XCTAssertTrue(f.pinned)
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.jumpedToLatest()
        XCTAssertTrue(f.pinned)
    }

    func testStatusChangeAfterTheReadersMessageDoesNotDragThemDown() {
        var f = TranscriptFollowState()
        f.contentArrived(readerSent: true)
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.contentArrived(readerSent: false) // the agent starts running, an approval arrives
        XCTAssertFalse(f.pinned)
    }

    func testStatusOnlyChangeDoesNotOfferJumpToLatest() {
        var f = TranscriptFollowState()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.contentArrived(readerSent: false, newContent: false)
        XCTAssertFalse(f.newBelow)
    }

    func testReaderSendingWhileScrolledUpPins() {
        var f = TranscriptFollowState()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.contentArrived(readerSent: true)
        XCTAssertTrue(f.pinned)
        XCTAssertFalse(f.newBelow)
    }

    func testNewContentBelowShowsJumpButtonOnlyWhileUnpinned() {
        var f = TranscriptFollowState()
        f.contentArrived(readerSent: false)
        XCTAssertFalse(f.newBelow)
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.contentArrived(readerSent: false)
        XCTAssertTrue(f.newBelow)
        f.geometryChanged(distanceFromBottom: 0, userDriven: true)
        XCTAssertFalse(f.newBelow)
    }
}

/// A reader scrolled up must stay where they are while a reply streams in.
@MainActor
final class TranscriptFollowTests: XCTestCase {
    override func setUpWithError() throws {
        try CISkip.unlessLocal()
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func scrollView(_ panel: NSPanel) -> NSScrollView? { HugeTranscriptTests.scrollView(in: panel.contentView) }

    /// (distance from top, distance from bottom)
    private func position(_ panel: NSPanel) -> (top: CGFloat, bottom: CGFloat) {
        guard let scroll = scrollView(panel), let doc = scroll.documentView else { return (0, 0) }
        let v = scroll.contentView.bounds
        let top = doc.isFlipped ? v.minY : doc.bounds.maxY - v.maxY
        return (top, doc.bounds.height - v.height - top)
    }

    private func wheel(_ panel: NSPanel, toFraction f: CGFloat) {
        guard let scroll = scrollView(panel) else { return }
        for _ in 0..<600 {
            guard let doc = scroll.documentView else { return }
            let v = scroll.contentView.bounds
            let offset = doc.isFlipped ? v.minY : doc.bounds.maxY - v.maxY
            let delta = (doc.bounds.height - v.height) * f - offset
            if abs(delta) < 40 { break }
            let step = Int32(max(-3000, min(3000, delta)))
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { return }
            scroll.scrollWheel(with: event)
            spin(0.04)
        }
        spin(1)
    }

    private func open() -> (ChatSession, IronPetPanel) {
        let session = ChatSession(restore: false)
        session.items = HugeTranscriptTests.hugeThread(screenshotDir: nil)
        let panel = IronPetPanel.chat(session)
        panel.setContentSize(CGSize(width: 520, height: 640))
        panel.orderFrontRegardless()
        spin(3)
        return (session, panel)
    }

    private func stream(_ session: ChatSession, words: Int) {
        session.items.append(.init(kind: .assistant("")))
        let index = session.items.count - 1
        var text = ""
        for i in 0..<words {
            text += "word\(i) "
            session.items[index].kind = .assistant(text)
            if i % 4 == 0 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004)) }
        }
        spin(1)
    }

    private func snapshot(_ panel: NSPanel, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["IRONPET_SNAPSHOTS"], let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func testScrolledUpStaysPutWhileReplyStreams() throws {
        // The rendered window is the newest 150 items. In `hugeThread` that is one 800 pt run of tool steps, too short to scroll
        // up in, so this uses turns whose rows have a height of their own.
        let (session, panel) = open(items: mixedThread(turns: 200))
        wheel(panel, toFraction: 0.5)
        let before = position(panel)
        snapshot(panel, "scrolledup-before")
        stream(session, words: 1500)
        session.items.append(.init(kind: .tool("Ran `ls`", ok: true)))
        session.items.append(.init(kind: .assistant("A later message")))
        spin(1)
        let after = position(panel)
        snapshot(panel, "scrolledup-after")
        print("FOLLOW scrolled up: top \(before.top) -> \(after.top), bottom gap \(before.bottom) -> \(after.bottom)")
        panel.close()
        XCTAssertEqual(after.top, before.top, accuracy: 40, "the transcript moved while the reader was scrolled up")
    }

    /// The invariant is the row the reader sees, not the offset: SwiftUI shifts the offset by hundreds of points when a
    /// new row changes its height estimates, and keeps the row where it was.
    func testScrolledUpKeepsTheSameRowWhileContentArrives() throws {
        let (session, panel) = open()
        wheel(panel, toFraction: 0.5)
        func topIndex() -> Int? { ChatView.topRowForTesting.flatMap { id in session.items.firstIndex { $0.id == id } } }
        let before = try XCTUnwrap(topIndex(), "SwiftUI reported no top row")
        stream(session, words: 800)
        session.items.append(.init(kind: .tool("Ran `ls`", ok: true)))
        session.items.append(.init(kind: .assistant("A later message")))
        session.items.append(.init(kind: .user("A message from Telegram"), origin: ChatOrigin.telegramClient))
        spin(1.5)
        let after = try XCTUnwrap(topIndex())
        print("FOLLOW top row index \(before) -> \(after)")
        panel.close()
        XCTAssertEqual(after, before, "the row the reader was looking at changed")
    }

    func testPinnedKeepsFollowingWhileReplyStreams() throws {
        let (session, panel) = open()
        stream(session, words: 1500)
        let after = position(panel)
        snapshot(panel, "pinned-after")
        print("FOLLOW pinned: bottom gap \(after.bottom)")
        panel.close()
        XCTAssertLessThan(after.bottom, 60, "stopped following the bottom")
    }

    func testScrollingBackDownResumesFollowing() throws {
        let (session, panel) = open()
        wheel(panel, toFraction: 0.5)
        stream(session, words: 300)
        for _ in 0..<5 where position(panel).bottom > 20 { wheel(panel, toFraction: 1) }
        print("FOLLOW reader reached bottom: gap \(position(panel).bottom)")
        stream(session, words: 1500)
        let after = position(panel)
        print("FOLLOW resumed: bottom gap \(after.bottom)")
        panel.close()
        XCTAssertLessThan(after.bottom, 60, "did not resume following after scrolling to the bottom")
    }

    /// Questions, tool rows and long replies, so rows have different heights.
    private func mixedThread(turns: Int) -> [ChatSession.Item] {
        let long = (0..<6).map { "Sentence \($0) of a long reply that wraps across several lines in the chat column." }.joined(separator: " ")
        var items: [ChatSession.Item] = []
        for i in 0..<turns {
            items.append(.init(kind: .user("Question \(i) \(long)")))
            for j in 0..<(i % 3 + 1) { items.append(.init(kind: .tool("Ran `step \(i)-\(j)`", ok: true))) }
            items.append(.init(kind: .assistant(long + "\n\n" + long)))
        }
        return items
    }

    private func open(items: [ChatSession.Item]) -> (ChatSession, IronPetPanel) {
        let session = ChatSession(restore: false)
        session.items = items
        let panel = IronPetPanel.chat(session)
        panel.setContentSize(CGSize(width: 520, height: 640))
        panel.orderFrontRegardless()
        spin(3)
        return (session, panel)
    }

    /// S1: rows appended and updated while the view is at the end must not move it, and the content height must not
    /// jump, which is what moved the offset when the transcript was a lazy stack.
    func testPinnedViewStaysAtTheEndWhileRowsAreAppendedAndUpdated() throws {
        let (session, panel) = open(items: mixedThread(turns: 30))
        session.items.append(.init(kind: .tool("Ran `ls`", ok: true)))
        spin(1)
        var worstAbove: CGFloat = 0
        var lastHeight: CGFloat?
        var biggestChange: CGFloat = 0
        let end = Date().addingTimeInterval(6)
        var tick = 0
        while Date() < end {
            tick += 1
            if tick % 6 == 0 { session.items.append(.init(kind: .tool("Ran `bg \(tick)`", ok: true))) }
            session.items[session.items.count - 1].kind = .tool("Ran \(tick % 7 + 1) commands", ok: tick % 2 == 0)
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            worstAbove = max(worstAbove, position(panel).bottom)
            if let height = scrollView(panel)?.documentView?.bounds.height {
                if let last = lastHeight { biggestChange = max(biggestChange, abs(height - last)) }
                lastHeight = height
            }
        }
        panel.close()
        XCTAssertLessThan(worstAbove, 60, "the view left the end while rows updated")
        // The oldest row leaves the window as new ones arrive, which is at most one turn. A lazy stack moved by thousands.
        XCTAssertLessThan(biggestChange, 1500, "the content height jumped while rows updated")
    }

    /// Reaching the top of the rendered rows loads the next page of older ones and keeps the reader on the same row: the
    /// offset grows by the height the new rows added.
    func testScrollingToTheTopLoadsOlderRowsAndKeepsTheReadersRow() throws {
        let (_, panel) = open(items: mixedThread(turns: 200))
        let scroll = try XCTUnwrap(scrollView(panel))
        let startHeight = try XCTUnwrap(scroll.documentView).bounds.height
        var grown: (before: CGFloat, after: CGFloat)?
        for _ in 0..<120 {
            let before = try XCTUnwrap(scroll.documentView).bounds.height
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 500, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { break }
            scroll.scrollWheel(with: event)
            spin(0.1)
            let after = try XCTUnwrap(scroll.documentView).bounds.height
            if after > before + 2000 { grown = (before, after); break }
        }
        let heights = try XCTUnwrap(grown, "older rows were not loaded at the top (content stayed \(Int(startHeight)) pt)")
        spin(0.8)
        let offset = position(panel).top
        panel.close()
        XCTAssertEqual(offset, heights.after - heights.before, accuracy: 400, "the reader was not kept on the row they were reading")
    }

    func testSendingJumpsToBottom() throws {
        let (session, panel) = open()
        wheel(panel, toFraction: 0.3)
        session.items.append(.init(kind: .user("hello")))
        spin(2)
        XCTAssertLessThan(position(panel).bottom, 60)
        panel.close()
    }
}

final class BlankViewportGuardTests: XCTestCase {
    func testNeverFiresWhileARowIsVisible() {
        var guardrail = BlankViewportGuard()
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 1, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 3, hasRows: true, contentHeight: 9000, viewportHeight: 600, distanceFromBottom: -700))
    }

    func testFiresOnlyWhenEmptyWithTallContent() {
        var guardrail = BlankViewportGuard()
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: false, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 400, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 0, distanceFromBottom: -700))
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
    }

    func testIgnoresAViewportThatStillOverlapsTheContent() {
        var guardrail = BlankViewportGuard()
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: 900))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: 0))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -10))
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -200))
    }

    func testFiresOncePerContentHeightAndRearmsWhenRowsReturn() {
        var guardrail = BlankViewportGuard()
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5200, viewportHeight: 600, distanceFromBottom: -700))
        guardrail.rowsVisible()
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5200, viewportHeight: 600, distanceFromBottom: -700))
    }
}
