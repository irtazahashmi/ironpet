import AppKit
import SwiftUI

/// What one send to the larger model shows as in the Screen section.
struct ScreenSendRow: Equatable, Identifiable {
    var id: Int64
    var at: Date
    /// The time of day, such as "22:52".
    var time: String
    /// "8 items".
    var items: String
    /// "2 suggestions". Nil when the send produced none, so the row shows no badge.
    var suggestions: String?
    /// "1 redacted". Nil when nothing was redacted.
    var redacted: String?
    var hasSuggestions: Bool { suggestions != nil }
}

/// The sends of one day, under a heading such as "Today".
struct ScreenSendDay: Equatable, Identifiable {
    var title: String
    var rows: [ScreenSendRow]
    var id: String { title }
}

/// The text of the Screen section, kept apart from the view so tests can check it.
enum ScreenSectionText {
    static func summary(items: Int, pending: Int, localOnly: Int) -> String {
        "\(items) items, \(pending) waiting, \(localOnly) kept on this Mac"
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// One row per send, newest first.
    /// `suggestions` is each send's suggestion count, taken from the stored suggestions rather than the log's outcome text.
    /// `redactions` is each send's redacted span count.
    static func rows(_ log: [CaptureSendRecord], suggestions: [Int64: Int] = [:], redactions: [Int64: Int] = [:],
                     locale: Locale = .current, timeZone: TimeZone = .current) -> [ScreenSendRow] {
        log.sorted { ($0.at, $0.id) > ($1.at, $1.id) }.map { record in
            ScreenSendRow(id: record.id,
                          at: record.at,
                          time: record.at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)),
                          items: count(record.items.count, "item"),
                          suggestions: suggestions[record.id].flatMap { $0 > 0 ? count($0, "suggestion") : nil },
                          redacted: redactions[record.id].flatMap { $0 > 0 ? "\($0) redacted" : nil })
        }
    }

    /// Rows grouped by day, newest day first: Today, Yesterday, then the date.
    static func days(_ rows: [ScreenSendRow], now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> [ScreenSendDay] {
        var days: [ScreenSendDay] = []
        for row in rows {
            let title = dayTitle(row.at, now: now, calendar: calendar, locale: locale)
            if let last = days.indices.last, days[last].title == title {
                days[last].rows.append(row)
            } else {
                days.append(ScreenSendDay(title: title, rows: [row]))
            }
        }
        return days
    }

    static func dayTitle(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: calendar.timeZone)
        style.calendar = calendar
        return date.formatted(style)
    }

    /// The agent and model a send went to, shown once in the batch detail.
    static func agent(_ record: CaptureSendRecord) -> String { "\(record.harness) / \(record.model)" }
}

/// The two tabs of the Screen section.
enum ScreenTab: String, CaseIterable, Identifiable {
    case captures, sent

    var id: String { rawValue }
    var title: String { self == .captures ? "Captures" : "Sent to the agent" }
}

/// The leading inset every part of the Screen section uses, the same as the page header's.
enum ScreenLayout {
    static let inset: CGFloat = 16
}

/// The Screen section: the capture counts above two tabs, what screen capture has stored and what it sent to the agent.
struct ScreenSection: View {
    @ObservedObject var model: CaptureStatusModel
    @ObservedObject private var config = ConfigStore.shared
    @Binding var tab: ScreenTab
    /// The capture database for the Captures tab. Nil before the app has started.
    var store: CaptureStore?
    var onOpenSettings: () -> Void = {}
    var onAppear: () -> Void = {}
    /// Reads one send's items and suggestions. Nil when the app has no task store.
    var loadBatch: (Int64) -> ScreenBatch? = { _ in nil }
    var loadCounts: ([Int64]) -> [Int64: Int] = { _ in [:] }
    var loadRedactions: ([Int64]) -> [Int64: Int] = { _ in [:] }
    var onAccept: (String) -> Void = { _ in }
    var onSkip: (String) -> Void = { _ in }

    @State private var selected: Int64?
    @State private var batch: ScreenBatch?
    @State private var counts: [Int64: Int] = [:]
    @State private var redactions: [Int64: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch tab {
            case .captures:
                if let store {
                    CaptureInspectorView(store: store)
                } else {
                    Text("Nothing has been captured yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .sent:
                if let batch {
                    ScrollView {
                        ScreenBatchView(batch: batch, onBack: { self.batch = nil; selected = nil; refresh() },
                                        onAccept: { onAccept($0); reload() }, onSkip: { onSkip($0); reload() })
                            .padding(ScreenLayout.inset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    sent
                }
            }
        }
        .frame(maxHeight: .infinity)
        .pageHeader(IronPetSection.screen.title)
        .onAppear { onAppear(); refresh() }
        .onChange(of: model.sendLog) { _ in refresh() }
    }

    private func refresh() {
        let ids = model.sendLog.map(\.id)
        counts = loadCounts(ids)
        redactions = loadRedactions(ids)
    }

    private func reload() {
        if let selected { batch = loadBatch(selected) }
        refresh()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                ScreenStat(value: model.itemCount, label: "Captured")
                ScreenStat(value: model.pendingCount, label: "Waiting")
                ScreenStat(value: model.localOnlyCount, label: "Kept on this Mac")
                Spacer(minLength: 0)
            }
            if !config.config.screenCapture.enabled {
                HStack {
                    Label("Screen capture is off", systemImage: "pause.circle").foregroundStyle(.secondary)
                    Button("Open Settings", action: onOpenSettings)
                }
                .font(.callout)
            }
            Picker("Screen", selection: $tab) {
                ForEach(ScreenTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
        }
        .padding(.horizontal, ScreenLayout.inset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var sent: some View {
        let days = ScreenSectionText.days(ScreenSectionText.rows(model.sendLog, suggestions: counts, redactions: redactions))
        if days.isEmpty {
            Text("Nothing has been sent to the agent yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(days) { day in
                    Section(day.title) {
                        ForEach(day.rows) { row in
                            Button {
                                selected = row.id
                                batch = loadBatch(row.id)
                            } label: {
                                ScreenSendRowView(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

/// One number over its label, in the header.
private struct ScreenStat: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A small capsule with a count, such as "2 suggestions".
private struct ScreenBadge: View {
    let text: String
    let color: Color
    var filled = true

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(filled ? color : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(filled ? color.opacity(0.15) : Color.secondary.opacity(0.12)))
    }
}

private struct ScreenSendRowView: View {
    let row: ScreenSendRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.time).font(.body.monospacedDigit().weight(row.hasSuggestions ? .semibold : .regular))
                .foregroundStyle(row.hasSuggestions ? .primary : .secondary)
            Text(row.items).foregroundStyle(row.hasSuggestions ? .primary : .secondary)
            Spacer(minLength: 8)
            if let redacted = row.redacted { ScreenBadge(text: redacted, color: .secondary, filled: false) }
            if let suggestions = row.suggestions { ScreenBadge(text: suggestions, color: .accentColor) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// One send: the items it carried, the redaction summary, and every suggestion it produced with what happened to it.
struct ScreenBatchView: View {
    let batch: ScreenBatch
    var onBack: () -> Void = {}
    var onAccept: (String) -> Void = { _ in }
    var onSkip: (String) -> Void = { _ in }

    @State private var open: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { onBack() } label: { Label("Sent to the agent", systemImage: "chevron.left") }
                .buttonStyle(.link)
            let record = batch.record
            VStack(alignment: .leading, spacing: 4) {
                Text(record.at.formatted(date: .complete, time: .shortened)).font(.title3.weight(.semibold))
                Text(ScreenBatchText.facts(record, redactions: batch.redactions)).font(.callout).foregroundStyle(.secondary)
            }
            group(ScreenBatchText.suggestionsTitle(batch.suggestions.count)) {
                if batch.suggestions.isEmpty {
                    Text("The agent found nothing to suggest in this send.").foregroundStyle(.secondary)
                }
                ForEach(batch.suggestions) { suggestion(for: $0) }
            }
            group("Items (\(batch.items.count))") {
                if batch.items.isEmpty {
                    Text("This send had no items.").foregroundStyle(.secondary)
                }
                ForEach(batch.items) { item(for: $0) }
            }
            Text("The text shown is the redacted text stored on this Mac, which is what was sent. It is never logged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    private func suggestion(for s: ScreenBatch.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.title).fontWeight(.medium)
                Spacer(minLength: 8)
                Text(ScreenBatchLoader.label(s.kind)).font(.caption).foregroundStyle(.secondary)
            }
            if !s.quote.isEmpty { Text("\u{201C}\(s.quote)\u{201D}").font(.callout).foregroundStyle(.secondary) }
            Text(ScreenBatchText.outcome(s.outcome)).font(.caption).foregroundStyle(.secondary)
            if case .pending(let id) = s.outcome {
                HStack {
                    Button("Accept") { onAccept(id) }
                    Button("Skip") { onSkip(id) }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func item(for item: ScreenBatch.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if open.contains(item.id) { open.remove(item.id) } else { open.insert(item.id) }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ScreenBatchText.itemTitle(item))
                        Text(ScreenBatchText.itemDetail(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: open.contains(item.id) ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.contains(item.id) {
                Text(item.body.isEmpty ? "No text is stored for this item." : item.body)
                    .font(.caption).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The wording of the batch view, kept apart so tests can check it.
enum ScreenBatchText {
    static func suggestionsTitle(_ n: Int) -> String { n == 0 ? "Suggestions" : "Suggestions (\(n))" }

    /// The agent, model, size and redaction summary of one send, in one line.
    static func facts(_ record: CaptureSendRecord, redactions: CaptureRedactor.Report) -> String {
        [ScreenSectionText.agent(record), ScreenSectionText.count(record.items.count, "item"),
         ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file), redactions.summary].joined(separator: ", ")
    }

    static func outcome(_ outcome: ScreenBatch.Suggestion.Outcome) -> String {
        switch outcome {
        case .pending: return "Waiting for review"
        case .accepted(let task, let title): return "Accepted" + (title.map { ": \($0)" } ?? task.map { ": task \($0)" } ?? "")
        case .rejected(let note): return "Rejected" + (note.map { ": \($0)" } ?? "")
        }
    }

    static func itemTitle(_ item: ScreenBatch.Item) -> String {
        guard let app = item.app else { return "Item \(item.id) (no longer stored)" }
        return "\(app): \(item.title ?? "")"
    }

    static func itemDetail(_ item: ScreenBatch.Item) -> String {
        guard let at = item.at else { return "Removed from the capture history" }
        return "\(at.formatted(date: .abbreviated, time: .shortened)), \(item.state ?? "")"
    }
}
