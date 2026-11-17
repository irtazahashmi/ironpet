import AppKit
import SwiftUI

// Design prototypes for the Screen section, rendered by `--render-previews` from sample data only.
// Delete this file once a direction is chosen.

private enum DesignSample {
    struct Capture: Identifiable {
        var id: Int
        var app: String, symbol: String, thread: String, time: String, snippet: String, state: String
    }

    static let now = Date()
    static func record(_ id: Int64, _ ago: TimeInterval, items: Int) -> CaptureSendRecord {
        CaptureSendRecord(id: id, at: now.addingTimeInterval(-ago), harness: "claude", model: "haiku",
                          items: Array(1...Int64(items)), bytes: items * 2_300, outcome: "sent")
    }

    static let sugg: [Int64: [ScreenBatch.Suggestion]] = [
        6: [.init(id: "a", kind: "new_task", title: "Send the invoice to Ana", quote: "please send the invoice by Friday", outcome: .pending(id: "a")),
            .init(id: "b", kind: "calendar", title: "Dentist, Thursday 9:30", quote: "see you Thursday at 9:30", outcome: .pending(id: "b"))],
        3: [.init(id: "c", kind: "update", title: "Pay the rent", quote: "rent paid", outcome: .accepted(task: "t", title: "Pay the rent"))],
    ]
    static let redacted: [Int64: Int] = [5: 1, 4: 2]
    static let log: [CaptureSendRecord] = [
        record(6, 600, items: 8), record(5, 4_000, items: 3), record(4, 8_000, items: 5), record(3, 100_000, items: 2),
        record(2, 105_000, items: 4), record(1, 400_000, items: 1),
    ]

    static func batch(_ id: Int64) -> ScreenBatch {
        let rec = log.first { $0.id == id }!
        let items = rec.items.prefix(3).map { n in
            ScreenBatch.Item(id: n, app: n % 2 == 0 ? "Mail" : "Slack", title: n % 2 == 0 ? "Invoice 42" : "acme/ana",
                             at: rec.at.addingTimeInterval(-Double(n) * 60), state: "sent", body: "", redactions: CaptureRedactor.Report())
        }
        return ScreenBatch(record: rec, items: Array(items), suggestions: sugg[id] ?? [], redactions: CaptureRedactor.Report())
    }

    static let captures: [Capture] = [
        .init(id: 1, app: "Slack", symbol: "bubble.left.and.bubble.right", thread: "acme/ana", time: "23:41", snippet: "Please send the invoice by Friday", state: "waiting"),
        .init(id: 2, app: "Mail", symbol: "envelope", thread: "Rent is due", time: "23:12", snippet: "Rent is due on the 1st", state: "passed"),
        .init(id: 3, app: "Messages", symbol: "message", thread: "Sam", time: "22:58", snippet: "Call me when you land", state: "kept on Mac"),
        .init(id: 4, app: "Slack", symbol: "bubble.left.and.bubble.right", thread: "dev/builds", time: "22:30", snippet: "Build 4412 passed", state: "sent"),
    ]
    static var days: [ScreenSendDay] {
        ScreenSectionText.days(ScreenSectionText.rows(log, suggestions: sugg.mapValues(\.count), redactions: redacted), now: now)
    }
}

private struct Stat: View {
    let value: String, label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Tabs: View {
    @Binding var tab: ScreenTab
    var body: some View {
        Picker("Screen", selection: $tab) { ForEach(ScreenTab.allCases) { Text($0.title).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}

private struct Backdrop<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Screen").font(.system(size: 15, weight: .semibold)); Spacer() }
                .padding(.horizontal, 16).frame(height: 44)
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(1)
    }
}

// MARK: B, master and detail

private struct OptionB: View {
    @State var tab: ScreenTab
    var narrow = false
    @State private var selected: Int64 = 6

    var body: some View {
        Backdrop {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Tabs(tab: $tab)
                    Spacer()
                    if !narrow {
                        Text("1,595 captured").foregroundStyle(.secondary)
                        Text("2 waiting").foregroundStyle(.orange)
                        Text("1,028 kept on this Mac").foregroundStyle(.secondary)
                    }
                }
                .font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if narrow {
                    list.frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 0) {
                        list.frame(width: 280)
                        Divider()
                        detail
                    }
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        if tab == .sent {
            List(selection: Binding(get: { selected }, set: { selected = $0 ?? selected })) {
                ForEach(DesignSample.days) { day in
                    Section(day.title) {
                        ForEach(day.rows) { row in
                            HStack(spacing: 6) {
                                Text(row.time).monospacedDigit().fontWeight(row.hasSuggestions ? .semibold : .regular)
                                Text(row.items).foregroundStyle(.secondary)
                                Spacer()
                                if let s = row.suggestions {
                                    Label(s.components(separatedBy: " ")[0], systemImage: "sparkles").labelStyle(.titleAndIcon)
                                        .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                                }
                            }
                            .tag(row.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            List(selection: Binding(get: { Int64(1) }, set: { _ in })) {
                ForEach(DesignSample.captures) { c in
                    HStack(spacing: 8) {
                        Image(systemName: c.symbol).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.thread).lineLimit(1)
                            Text(c.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(c.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(Int64(c.id))
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var detail: some View {
        if tab == .sent {
            ScrollView {
                ScreenBatchView(batch: DesignSample.batch(selected), showsBack: false)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Slack", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Text("acme/ana").font(.title3.weight(.semibold))
                Text("Today at 23:41, waiting for the filter").font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("Ana: Please send the invoice by Friday").font(.system(.body, design: .monospaced))
                Spacer()
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: C, cards on a timeline

private struct OptionC: View {
    @State var tab: ScreenTab
    var narrow = false

    var body: some View {
        Backdrop {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        tile("1,595", "Captured", "tray.full")
                        tile("2", "Waiting", "hourglass")
                        if !narrow { tile("1,028", "Kept on this Mac", "lock") }
                    }
                    HStack { Spacer(); Tabs(tab: $tab); Spacer() }
                    if tab == .sent { timeline } else { captures }
                }
                .padding(16)
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            Stat(value: value, label: label)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(DesignSample.days) { day in
                Text(day.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                let hits = day.rows.filter(\.hasSuggestions)
                let quiet = day.rows.filter { !$0.hasSuggestions }
                ForEach(hits) { row in card(row) }
                if !quiet.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray").foregroundStyle(.tertiary)
                        Text("\(quiet.count) \(quiet.count == 1 ? "batch" : "batches"), nothing found").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    private func card(_ row: ScreenSendRow) -> some View {
        let list = DesignSample.sugg[row.id] ?? []
        return HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(row.suggestions ?? "", systemImage: "sparkles").font(.headline).foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("\(row.time), \(row.items)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(list) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.kind == "calendar" ? "calendar" : s.kind == "update" ? "checkmark.circle" : "plus.circle")
                            .foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title)
                            Text(ScreenBatchText.outcome(s.outcome)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var captures: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(DesignSample.captures) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.symbol).frame(width: 28, height: 28)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(c.thread).fontWeight(.medium); Spacer(); Text(c.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        Text(c.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Text(c.state).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

@MainActor
enum ScreenDesignOptions {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = CaptureStatusModel()
        model.itemCount = 1_595; model.pendingCount = 2; model.localOnlyCount = 1_028
        model.sendLog = DesignSample.log
        let store = CaptureStore(database: Database.open(path: nil, migrations: CaptureStore.migrations).database)
        for (thread, text) in [("slack:acme/ana", "Please send the invoice by Friday"), ("mail:rent", "Rent is due on the 1st")] {
            let item = CaptureItem(app: CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"), threadKey: thread, threadTitle: thread,
                                   content: .conversation(title: thread, isGroup: false, messages: [CaptureMessage(author: "Ana", text: text)]), parser: "preview")
            _ = try? store.ingest(item)
        }
        let counts = DesignSample.sugg.mapValues(\.count)
        func a(_ tab: ScreenTab, _ w: CGFloat) -> some View {
            ScreenSection(model: model, tab: .constant(tab), store: store,
                          loadCounts: { _ in counts }, loadRedactions: { _ in DesignSample.redacted })
                .frame(width: w, height: 700)
                .background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1)).padding(1)
        }
        PreviewRenderer.render(a(.sent, 900), to: dir, "A-sent")
        PreviewRenderer.render(a(.sent, 420), to: dir, "A-sent-narrow")
        PreviewRenderer.render(a(.captures, 900), to: dir, "A-captures")
        PreviewRenderer.render(Backdrop { ScrollView { ScreenBatchView(batch: DesignSample.batch(6)).padding(16).frame(maxWidth: .infinity, alignment: .leading) } }
            .frame(width: 900, height: 700), to: dir, "A-batch")
        PreviewRenderer.render(OptionB(tab: .sent).frame(width: 900, height: 700), to: dir, "B-sent")
        PreviewRenderer.render(OptionB(tab: .sent, narrow: true).frame(width: 420, height: 700), to: dir, "B-sent-narrow")
        PreviewRenderer.render(OptionB(tab: .captures).frame(width: 900, height: 700), to: dir, "B-captures")
        PreviewRenderer.render(OptionC(tab: .sent).frame(width: 900, height: 700), to: dir, "C-sent")
        PreviewRenderer.render(OptionC(tab: .sent, narrow: true).frame(width: 420, height: 700), to: dir, "C-sent-narrow")
        PreviewRenderer.render(OptionC(tab: .captures).frame(width: 900, height: 700), to: dir, "C-captures")
        PreviewRenderer.render(OptionB(tab: .sent).frame(width: 900, height: 700), to: dir, "B-sent-light", scheme: .light)
        PreviewRenderer.render(OptionC(tab: .sent).frame(width: 900, height: 700), to: dir, "C-sent-light", scheme: .light)
        PreviewRenderer.render(a(.sent, 900), to: dir, "A-sent-light", scheme: .light)
    }
}
