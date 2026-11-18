import XCTest
@testable import IronPet

@MainActor
final class ScreenSectionTests: XCTestCase {
    func testSummaryMatchesTheStatusCounts() {
        let model = CaptureStatusModel()
        model.itemCount = 1595
        model.pendingCount = 2
        model.localOnlyCount = 1028
        XCTAssertEqual(ScreenSectionText.summary(items: model.itemCount, pending: model.pendingCount, localOnly: model.localOnlyCount),
                       "1595 items, 2 waiting, 1028 kept on this Mac")
    }

    private let utc = TimeZone(identifier: "UTC")!
    private let en = Locale(identifier: "en_GB")

    private func record(_ id: Int64, _ at: Date, items: Int = 8) -> CaptureSendRecord {
        CaptureSendRecord(id: id, at: at, harness: "claude", model: "haiku", items: Array(1...Int64(items)), bytes: 18_814, outcome: "sent")
    }

    func testRowsListNewestFirstWithTimeAndItemCount() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = ScreenSectionText.rows([record(1, base, items: 1), record(2, base.addingTimeInterval(60))], locale: en, timeZone: utc)
        XCTAssertEqual(rows.map(\.id), [2, 1])
        XCTAssertEqual(rows[0].items, "8 items")
        XCTAssertEqual(rows[1].items, "1 item")
        XCTAssertTrue(rows[0].time.hasSuffix("8:01"), rows[0].time)
    }

    func testSuggestionAndRedactionBadgesShowOnlyAboveZero() {
        let log = [record(1, Date()), record(2, Date().addingTimeInterval(1)), record(3, Date().addingTimeInterval(2))]
        let rows = ScreenSectionText.rows(log, suggestions: [1: 0, 2: 1, 3: 2], redactions: [1: 0, 2: 1, 3: 3])
        XCTAssertEqual(rows.map(\.suggestions), ["2 suggestions", "1 suggestion", nil])
        XCTAssertEqual(rows.map(\.redacted), ["3 redacted", "1 redacted", nil])
        XCTAssertEqual(rows.map(\.hasSuggestions), [true, true, false])
        XCTAssertNil(ScreenSectionText.rows(log)[0].suggestions)
    }

    func testRowsGroupByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = now.addingTimeInterval(-3_600)
        let yesterday = now.addingTimeInterval(-86_400)
        let old = now.addingTimeInterval(-5 * 86_400)
        let rows = ScreenSectionText.rows([record(1, old), record(2, yesterday), record(3, earlier), record(4, now)], locale: en, timeZone: utc)
        let days = ScreenSectionText.days(rows, now: now, calendar: calendar, locale: en)
        XCTAssertEqual(days.map(\.title).prefix(2), ["Today", "Yesterday"])
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].rows.map(\.id), [4, 3])
        XCTAssertEqual(days[2].rows.map(\.id), [1])
        XCTAssertFalse(["Today", "Yesterday"].contains(days[2].title))
    }

    func testQuietBatchesCollapseIntoOneLine() {
        XCTAssertEqual(ScreenSectionText.quietTitle(1), "1 batch, nothing found")
        XCTAssertEqual(ScreenSectionText.quietTitle(3), "3 batches, nothing found")
    }

    func testOutcomeChipsAndDetails() {
        XCTAssertEqual(ScreenBatchText.outcomeShort(.pending(id: "a")), "Pending")
        XCTAssertEqual(ScreenBatchText.outcomeShort(.accepted(task: "t", title: "Pay")), "Accepted")
        XCTAssertEqual(ScreenBatchText.outcomeDetail(.rejected(note: "done already")), "done already")
        XCTAssertNil(ScreenBatchText.outcomeDetail(.pending(id: "a")))
    }

    func testCaptureDetailWords() {
        var row = CaptureStore.InspectRow(id: 1, at: Date(), app: "x", appName: "X", threadKey: "k", threadTitle: "t", kind: "conversation",
                                          url: nil, version: 1, newMessages: 0, body: "", state: "new", reason: nil, secret: nil,
                                          calendar: nil, task: nil, related: nil, sentAt: nil)
        XCTAssertEqual(CaptureInspectorView.secretText(row), "Not checked by a model")
        row.secret = 0.93
        row.state = "local"
        row.reason = CaptureDecisionFilter.flaggedReason
        XCTAssertEqual(CaptureInspectorView.secretText(row).hasSuffix("flagged"), true)
        XCTAssertTrue(CaptureInspectorView.stateText(row).hasPrefix("Kept on this Mac. Still flagged"))
    }

    func testBatchFactsNameAgentOnceWithSizeAndRedactions() {
        let facts = ScreenBatchText.facts(record(1, Date()), redactions: CaptureRedactor.Report())
        XCTAssertTrue(facts.hasPrefix("claude / haiku, 8 items, "))
        XCTAssertTrue(facts.hasSuffix("nothing redacted"))
    }

    func testScreenSectionComesAfterTranscriptsAndIsAlwaysListed() {
        let shown = IronPetSection.shown(chat: false, transcripts: true, automations: false)
        XCTAssertEqual(shown.firstIndex(of: .screen), shown.firstIndex(of: .transcripts)! + 1)
    }
}

@MainActor
final class ScreenTabTests: XCTestCase {
    func testTwoTabsCapturesFirst() {
        XCTAssertEqual(ScreenTab.allCases, [.captures, .sent])
        XCTAssertEqual(ScreenTab.allCases.map(\.title), ["Captures", "Sent to the agent"])
    }

    func testWindowModelOpensOnCapturesAndKeepsTheChosenTab() {
        let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ScreenTabTests-\(UUID().uuidString)")!)
        XCTAssertEqual(model.screenTab, .captures)
        model.screenTab = .sent
        XCTAssertEqual(model.screenTab, .sent)
    }
}
