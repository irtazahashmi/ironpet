import Foundation
import IronPetKit
import XCTest
@testable import IronPet

/// `Bubble` is plain data. Its closures live in a `BubbleActionTable`, found by bubble id and control id.
@MainActor
final class BubbleDataTests: XCTestCase {
    private func sample() -> Bubble {
        Bubble(id: "b", symbol: "calendar", tint: .orange, title: "Due", subtitle: "Today", body: "Send the report",
               lines: [.init(id: "line:0", symbol: "x", tint: .red, text: "One")],
               actions: [.init(id: "done", title: "Done", style: .primary), .init(id: "snooze", title: "Snooze")],
               tappable: true, expires: Date(timeIntervalSince1970: 1_000), contentKind: .meeting, macOnly: true)
    }

    // S1

    func testABubbleRoundTripsThroughJSONWithEveryField() throws {
        let bubble = sample()
        let back = try JSONDecoder().decode(Bubble.self, from: JSONEncoder().encode(bubble))
        XCTAssertEqual(back, bubble)
        XCTAssertEqual(back.tint, .orange)
        XCTAssertEqual(back.actions.map(\.id), ["done", "snooze"])
        XCTAssertEqual(back.actions.map(\.style), [.primary, .normal])
        XCTAssertEqual(back.lines.map(\.id), ["line:0"])
        XCTAssertEqual(back.contentKind, .meeting)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bubble)) as? [String: Any])
        XCTAssertEqual(object["tint"] as? String, "orange", "the tint is a name, not a color")
        XCTAssertEqual(object["contentKind"] as? String, "meeting")
    }

    func testTheDataTypeFilesImportNoUIFramework() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Bubble.swift", "BubbleActionTable.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/IronPet/Pet/\(name)"), encoding: .utf8)
            for banned in ["import SwiftUI", "import AppKit", "import Combine", "AnyView", "Color"] {
                XCTAssertFalse(source.contains(banned), "\(name) must not contain \(banned)")
            }
        }
    }

    // S2

    func testPressingByBubbleIdAndActionIdRunsTheRegisteredClosure() throws {
        let store = BubbleStore()
        var done = 0, snoozed = 0, tapped = 0, line = 0
        store.show(BubbleDraft(id: "due", symbol: "calendar", tint: .blue, title: "Task due",
                               lines: [.init(id: "l", symbol: "x", tint: .blue, text: "t") { line += 1 }],
                               actions: [.init("done", "Done", style: .primary) { done += 1 }, .init("snooze", "Snooze") { snoozed += 1 }],
                               onTap: { tapped += 1 }))
        try store.actions.runAction(bubble: "due", action: "snooze")
        try store.actions.runAction(bubble: "due", action: "done")
        try store.actions.runLine(bubble: "due", line: "l")
        try store.actions.runTap(bubble: "due")
        XCTAssertEqual([done, snoozed, tapped, line], [1, 1, 1, 1])
    }

    func testAnUnknownActionOrBubbleThrowsNotFound() {
        let store = BubbleStore()
        store.show(BubbleDraft(id: "x", symbol: "star", tint: .blue, title: "X", actions: [.init("a", "A") {}]))
        XCTAssertThrowsError(try store.actions.runAction(bubble: "x", action: "nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertThrowsError(try store.actions.runAction(bubble: "gone", action: "a")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertThrowsError(try store.actions.runTap(bubble: "x")) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
    }

    func testDismissingABubbleDropsItsClosures() throws {
        let store = BubbleStore()
        store.show(BubbleDraft(id: "x", symbol: "star", tint: .blue, title: "X", actions: [.init("a", "A") {}]))
        store.dismiss("x")
        XCTAssertThrowsError(try store.actions.runAction(bubble: "x", action: "a"))
    }

    func testReplacingABubbleReplacesItsClosures() throws {
        let store = BubbleStore()
        var first = 0, second = 0
        store.show(BubbleDraft(id: "x", symbol: "star", tint: .blue, title: "X", actions: [.init("a", "A") { first += 1 }]))
        store.show(BubbleDraft(id: "x", symbol: "star", tint: .blue, title: "X", actions: [.init("a", "A") { second += 1 }]))
        try store.actions.runAction(bubble: "x", action: "a")
        XCTAssertEqual([first, second], [0, 1])
    }

    func testTheBuildersListNoControlWithoutAClosure() {
        let drafts = [
            Announcer.approvalBubble(id: UUID(), heading: "h", detail: "d", decide: { _ in }, openChat: {}, open: {}),
            Announcer.tasksDueBubble([], now: Date(), done: {}, snooze: {}, open: {}),
        ]
        for draft in drafts { XCTAssertTrue(draft.handlers.covers(draft.bubble), draft.id) }
        XCTAssertEqual(drafts[0].bubble.actions.map(\.id), ["allow", "deny", "open-chat"])
        XCTAssertEqual(drafts[1].bubble.actions.map(\.id), ["done", "snooze", "open"])
        XCTAssertTrue(drafts[0].bubble.tappable)
    }

    func testAutomationButtonsRunThroughTheTableAndDismiss() throws {
        let store = BubbleStore()
        var approved = 0
        let notice = AutomationNotice(id: "automation-approval:a1", symbol: "hand.raised.fill", tint: .warn, title: "Allow?",
                                      buttons: [.init(title: "Approve", primary: true) { approved += 1 }, .init(title: "Reject", destructive: true) {}])
        store.show(Announcer.automationBubble(notice, dismiss: { store.dismiss(notice.id) }, open: nil))
        XCTAssertEqual(store.bubbles.first?.actions.map(\.style), [.primary, .destructive])
        try store.actions.runAction(bubble: notice.id, action: "button:0")
        XCTAssertEqual(approved, 1)
        XCTAssertTrue(store.bubbles.isEmpty)
    }

    // S4

    func testAnOlderClientStillDecodesEveryRemoteBubbleField() throws {
        let golden = """
        {"bubbles":[{"id":"due","symbol":"calendar","title":"Task due","subtitle":"Today","body":"Send the report",
        "mac_only":false,"lines":["One"],"actions":[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","title":"Done","style":"primary"}],
        "expires":"2026-01-01T10:00:00Z"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(BubbleListResponse.self, from: Data(golden.utf8))
        XCTAssertEqual(old.bubbles.first?.actions.first?.title, "Done")

        // The new route output decodes with the same DTO and keeps each field's name and type.
        let store = BubbleStore()
        let api = BubblesAPI(store: store)
        store.show(BubbleDraft(id: "due", symbol: "calendar", tint: .blue, title: "Task due", subtitle: "Today", body: "Send the report",
                               lines: [.init(id: "line:0", symbol: "x", tint: .blue, text: "One") {}],
                               actions: [.init("done", "Done", style: .primary) {}], expires: Date(timeIntervalSince1970: 4_000_000_000)))
        let info = try XCTUnwrap(api.list().first)
        XCTAssertEqual(info.actions.first?.style, "primary")
        let dto = RemoteBubble(id: info.id, symbol: info.symbol, title: info.title, subtitle: info.subtitle, body: info.body,
                               lines: info.lines.map(\.text), actions: info.actions.map { RemoteBubbleAction(id: $0.id, title: $0.title, style: $0.style) },
                               macOnly: info.macOnly, expires: info.expires)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
        for key in ["id", "symbol", "title", "subtitle", "body", "lines", "actions", "mac_only", "expires"] {
            XCTAssertNotNil(object[key], "\(key) is still on the wire")
        }
    }
}
