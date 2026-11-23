import AppKit
import SwiftUI
import XCTest
@testable import IronPet
@testable import IronPetCore

/// The Screen, Transcripts, Notifications and Automations detail pages build their sections as cards. SwiftUI text is not readable
/// from a hosted view without a screen (the accessibility tree is empty), so each test hosts the view with sample data and checks
/// what layout and drawing show: the view takes room for its cards, and the cards paint something.
@MainActor
final class DetailCardsRestTests: XCTestCase {
    /// Hosts `view` at a fixed size and returns the drawn bitmap.
    private func snapshot(_ view: some View, width: CGFloat = 780, height: CGFloat = 900, scheme: ColorScheme = .light) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: width, height: height))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// How many pixel rows of `rep` differ from the first row, so a taller stack of cards scores higher than a short one.
    private func paintedRows(_ rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let bytesPerRow = rep.bytesPerRow, width = rep.pixelsWide, height = rep.pixelsHigh, channels = rep.samplesPerPixel
        func row(_ y: Int) -> [UInt8] { Array(UnsafeBufferPointer(start: data + y * bytesPerRow, count: width * channels)) }
        let background = row(height - 1)
        return (0..<height).filter { row($0) != background }.count
    }

    private func lastPaintedRow(_ rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let bytesPerRow = rep.bytesPerRow, width = rep.pixelsWide, height = rep.pixelsHigh, channels = rep.samplesPerPixel
        let background = Array(UnsafeBufferPointer(start: data + (height - 1) * bytesPerRow, count: width * channels))
        for y in stride(from: height - 1, through: 0, by: -1)
        where Array(UnsafeBufferPointer(start: data + y * bytesPerRow, count: width * channels)) != background { return y }
        return 0
    }

    private func notification(summary: String = "Notes for v2.4", description: String = "Drafted the notes.", links: Bool = true) -> NotificationItem {
        NotificationItem(id: "n1", created: Date(), source: "release-notes", type: .backgroundResult, title: "Release notes",
                         summary: summary, description: description,
                         links: links ? [NotificationLink(.url, "https://example.com/releases/2.4", label: "Draft on the wiki")] : [])
    }

    // MARK: Notifications (S3)

    func testTheNotificationDetailShowsACardForEachPartThatHasText() {
        XCTAssertEqual(NotificationDetail.sections(for: notification()), ["Summary", "Details", "Links"])
        XCTAssertEqual(NotificationDetail.sections(for: notification(description: "", links: false)), ["Summary"])
        XCTAssertEqual(NotificationDetail.sections(for: notification(summary: "Release notes", description: "Release notes", links: false)), [],
                       "text that repeats the title or the summary gets no card of its own")
    }

    func testTheNotificationDetailGrowsWithItsCards() throws {
        let full = try snapshot(NotificationDetail(item: notification(), opener: NotificationLinkOpener(), onBack: {}))
        let bare = try snapshot(NotificationDetail(item: notification(summary: "Release notes", description: "", links: false),
                                                   opener: NotificationLinkOpener(), onBack: {}))
        XCTAssertGreaterThan(lastPaintedRow(full), lastPaintedRow(bare) + 100, "the summary, details and links cards take room")
    }

    // MARK: Screen (S1)

    func testTheScreenCaptureDetailDrawsTheHeaderAndTheTextCard() throws {
        let short = try snapshot(ScreenCaptureDetail(title: "Slack: ana", app: "Slack", at: Date(), text: "Hi", onBack: {}))
        let long = try snapshot(ScreenCaptureDetail(title: "Slack: ana", app: "Slack", at: Date(), text: (1...12).map { "Line \($0)" }.joined(separator: "\n"), onBack: {}))
        XCTAssertGreaterThan(paintedRows(short), 100)
        XCTAssertGreaterThan(lastPaintedRow(long), lastPaintedRow(short) + 60, "the text sits in a card that grows with it")
    }

    // MARK: Transcripts (S2)

    func testTheTranscriptCardSaysWhenThereIsNothingToShow() throws {
        let filled = try snapshot(TranscriptTextCard(title: "Summary", text: "Ana will send the deck.\n\nBo books the room.\n\nCy owns the follow-up."), height: 300)
        let empty = try snapshot(TranscriptTextCard(title: "Transcript", text: nil), height: 300)
        XCTAssertGreaterThan(paintedRows(empty), 40, "an empty page still draws its card and the notice")
        XCTAssertGreaterThan(lastPaintedRow(filled), lastPaintedRow(empty), "the card grows around the text")
    }

    // MARK: Automations (S4)

    func testTheAutomationsScreenAndItsDetailAreCards() throws {
        let water = Automation(id: "water", name: "Water", trigger: .init(type: "interval", minutes: 45, clock: "wall"),
                               action: .init(type: "bubble", title: "Water", body: "Drink"), createdBy: "user")
        let api = APITestSupport.makeAPI(automations: [water]).automations
        func list(open: String? = nil) -> AutomationList {
            AutomationList(api: api, config: SettingsAPI.live, showLogs: { _ in }, createWithAgent: { _ in }, open: open)
        }
        let settings = try snapshot(list(), height: 1200)
        let detail = try snapshot(list(open: "water"))
        XCTAssertGreaterThan(lastPaintedRow(settings), 700, "five sections stack down the page")
        XCTAssertGreaterThan(paintedRows(detail), 200, "the open automation draws its header and summary cards")
    }

    func testTheAutomationLogWindowDrawsItsCardsWithNoRuns() throws {
        let model = AutomationLogModel()
        model.api = APITestSupport.makeAPI(automations: []).automations
        model.reload()
        let empty = try snapshot(AutomationLogView(model: model), width: 860, height: 520)
        XCTAssertGreaterThan(paintedRows(empty), 300, "the filter card, the list card and the detail card fill the window")
    }
}
