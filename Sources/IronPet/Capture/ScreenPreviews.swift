import AppKit
import SwiftUI

/// `--render-previews`: the Screen section from sample data only, in the states a reviewer opens.
@MainActor
enum ScreenPreviews {
    private struct Seed {
        let store: CaptureStore
        let model: CaptureStatusModel
        let suggestions: [Int64: [ScreenBatch.Suggestion]]
        let flagged: Int64
        let sent: Int64
        let unchecked: Int64
    }

    private static func seed() -> Seed {
        let now = Date()
        let store = CaptureStore(database: Database.open(path: nil, migrations: CaptureStore.migrations).database)
        func ingest(_ app: String, _ bundle: String, _ thread: String, _ text: String, _ ago: TimeInterval) -> Int64 {
            let item = CaptureItem(app: CaptureApp(bundleId: bundle, name: app), threadKey: thread, threadTitle: thread,
                                   content: .conversation(title: thread, isGroup: false, messages: [CaptureMessage(author: "Ana", text: text)]), parser: "preview")
            return (try? store.ingest(item, now: now.addingTimeInterval(-ago)))?.itemId ?? 0
        }
        let sent = ingest("Slack", "com.tinyspeck.slackmacgap", "acme/ana", "Please send the invoice by Friday. Billing key AKIAIOSFODNN7EXAMPLE", 700)
        let mail = ingest("Mail", "com.apple.mail", "Rent is due", "Rent is due on the 1st", 900)
        let flagged = ingest("Messages", "com.apple.MobileSMS", "Sam", "My card is 4111 1111 1111 1111, call me when you land", 1_500)
        let builds = ingest("Slack", "com.tinyspeck.slackmacgap", "dev/builds", "Build 4412 passed", 5_000)
        let unchecked = ingest("Notes", "com.apple.Notes", "Groceries", "Milk, eggs, coffee", 200)
        store.setState(sent, "sent", secret: 0.04, calendar: 0.12, task: 0.86)
        store.setState(mail, "sent", secret: 0.02, task: 0.31)
        store.setState(flagged, "local", reason: CaptureDecisionFilter.flaggedReason, secret: 0.93)
        store.setState(builds, "sent", secret: 0.01)
        store.setState(unchecked, "new")
        func send(_ ago: TimeInterval, _ items: [Int64], bytes: Int) { store.logSend(harness: "claude", model: "haiku", items: items, bytes: bytes, outcome: "sent", now: now.addingTimeInterval(-ago)) }
        send(5 * 86_400, [builds], bytes: 400)          // 1
        send(30 * 3_600, [mail, builds], bytes: 2_100)  // 2
        send(26 * 3_600, [builds], bytes: 700)          // 3
        send(8_000, [builds], bytes: 700)               // 4
        send(4_000, [mail], bytes: 900)                 // 5
        send(600, [sent, mail, builds], bytes: 5_400)   // 6
        store.markSent([sent, mail, builds], at: now.addingTimeInterval(-600))
        let model = CaptureStatusModel()
        model.itemCount = 1_595; model.pendingCount = 2; model.localOnlyCount = 1_028
        model.sendLog = store.sendLog()
        let suggestions: [Int64: [ScreenBatch.Suggestion]] = [
            6: [.init(id: "a", kind: "new_task", title: "Send the invoice to Ana", quote: "please send the invoice by Friday", outcome: .pending(id: "a")),
                .init(id: "b", kind: "update", title: "Pay the rent", quote: "rent is due on the 1st", outcome: .accepted(task: "t", title: "Pay the rent")),
                .init(id: "c", kind: "calendar", title: "Dentist, Thursday 9:30", quote: "see you Thursday at 9:30", outcome: .rejected(note: "already in the calendar"))],
            2: [.init(id: "d", kind: "new_task", title: "Book the car service", quote: "book it before March", outcome: .accepted(task: "t2", title: "Book the car service"))],
        ]
        return Seed(store: store, model: model, suggestions: suggestions, flagged: flagged, sent: sent, unchecked: unchecked)
    }

    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seed = seed()
        let loadBatch: (Int64) -> ScreenBatch? = { id in
            guard let record = seed.store.sendLog(limit: 100).first(where: { $0.id == id }) else { return nil }
            let items = record.items.map { n -> ScreenBatch.Item in
                guard let item = seed.store.item(id: n) else { return .init(id: n, app: nil, title: nil, at: nil, state: nil, body: "", redactions: CaptureRedactor.Report()) }
                return .init(id: n, app: item.appName, title: item.threadTitle, at: item.at, state: item.state, body: item.body, redactions: item.redactions)
            }
            var report = CaptureRedactor.Report()
            for item in items { report.merge(item.redactions) }
            return ScreenBatch(record: record, items: items, suggestions: seed.suggestions[id] ?? [], redactions: report)
        }
        func section(_ tab: ScreenTab, width: CGFloat, openBatch: Int64? = nil, openCapture: Int64? = nil) -> some View {
            ScreenSection(model: seed.model, tab: .constant(tab), store: seed.store, loadBatch: loadBatch,
                          loadSuggestions: { _ in seed.suggestions }, loadRedactions: { _ in [5: 1] },
                          openBatch: openBatch, openCapture: openCapture)
                .frame(width: width, height: width > 600 ? 700 : 760)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .padding(1)
        }
        let config = ConfigStore.shared.config
        var on = config
        on.screenCapture.enabled = true
        ConfigStore.shared.usePreview(on)
        let states: [(String, ScreenTab, Int64?, Int64?)] = [
            ("sent-list", .sent, nil, nil), ("captures-list", .captures, nil, nil),
            ("batch-opened", .sent, 6, nil), ("batch-nothing-found", .sent, 5, nil),
            ("capture-opened", .captures, nil, seed.sent), ("capture-flagged", .captures, nil, seed.flagged),
            ("capture-unchecked", .captures, nil, seed.unchecked),
        ]
        for (name, tab, batch, capture) in states {
            for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                for width in [900.0, 420.0] {
                    PreviewRenderer.render(section(tab, width: width, openBatch: batch, openCapture: capture),
                                           to: dir, "\(name)-\(Int(width))-\(suffix)", scheme: scheme)
                }
            }
        }
        var off = config
        off.screenCapture.enabled = false
        ConfigStore.shared.usePreview(off)
        PreviewRenderer.render(section(.sent, width: 900), to: dir, "sent-list-capture-off-900-dark")
        ConfigStore.shared.usePreview(config)
    }
}
