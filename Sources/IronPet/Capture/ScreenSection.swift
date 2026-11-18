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

    /// "3 batches, nothing found".
    static func quietTitle(_ n: Int) -> String { "\(n) \(n == 1 ? "batch" : "batches"), nothing found" }

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

extension View {
    /// The card every part of the Screen section sits in: a quiet fill, rounded corners, and an optional accent bar on the leading edge.
    func screenCard(accent: Color? = nil, padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .padding(.leading, accent == nil ? 0 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if let accent { Rectangle().fill(accent).frame(width: 4) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A small capsule such as "Accepted" or "1 redacted".
struct ScreenChip: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

extension ScreenBatch.Suggestion.Outcome {
    var color: Color {
        switch self {
        case .pending: return .accentColor
        case .accepted: return .green
        case .rejected: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "clock"
        case .accepted: return "checkmark"
        case .rejected: return "xmark"
        }
    }
}

extension ScreenBatchLoader {
    /// The symbol for a kind of suggestion.
    static func symbol(_ kind: String) -> String {
        ["calendar": "calendar", "update": "checkmark.circle"][kind] ?? "plus.circle"
    }
}

/// The Screen section: what screen capture stored and what it sent to the agent, as cards on a timeline. The tabs sit in the page header.
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
    /// The suggestions each send produced, by send id.
    var loadSuggestions: ([Int64]) -> [Int64: [ScreenBatch.Suggestion]] = { _ in [:] }
    var loadRedactions: ([Int64]) -> [Int64: Int] = { _ in [:] }
    var onAccept: (String) -> Void = { _ in }
    var onSkip: (String) -> Void = { _ in }
    /// Opens this send or capture item when the section appears, for previews.
    var openBatch: Int64?
    var openCapture: Int64?

    @State private var batch: ScreenBatch?
    @State private var selected: Int64?
    @State private var suggestions: [Int64: [ScreenBatch.Suggestion]] = [:]
    @State private var redactions: [Int64: Int] = [:]
    @State private var openedCapture: Int64?
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let batch {
                    ScreenBatchView(batch: batch, onBack: { self.batch = nil; selected = nil; refresh() },
                                    onAccept: { onAccept($0); reload() }, onSkip: { onSkip($0); reload() })
                } else if tab == .captures, openedCapture != nil, let store {
                    CaptureInspectorView(store: store, opened: $openedCapture, onOpenBatch: open)
                } else {
                    stats
                    if tab == .sent {
                        sent
                    } else if let store {
                        CaptureInspectorView(store: store, opened: $openedCapture, onOpenBatch: open)
                    } else {
                        Text("Nothing has been captured yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(ScreenLayout.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .pageHeader(IronPetSection.screen.title) {
            Picker("Screen", selection: $tab) {
                ForEach(ScreenTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .onAppear {
            onAppear(); refresh()
            if let openBatch { tab = .sent; selected = openBatch; batch = loadBatch(openBatch) }
            if let openCapture { tab = .captures; openedCapture = openCapture }
        }
        .onChange(of: model.sendLog) { _ in refresh() }
        .onChange(of: tab) { _ in batch = nil; selected = nil; openedCapture = nil }
    }

    /// Shows one send in the Sent to the agent tab.
    private func open(batch id: Int64) {
        tab = .sent
        openedCapture = nil
        selected = id
        batch = loadBatch(id)
    }

    private func refresh() {
        let ids = model.sendLog.map(\.id)
        suggestions = loadSuggestions(ids)
        redactions = loadRedactions(ids)
    }

    private func reload() {
        if let selected { batch = loadBatch(selected) }
        refresh()
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ScreenStatTile(value: model.itemCount, label: "Captured", symbol: "tray.full")
                ScreenStatTile(value: model.pendingCount, label: "Waiting", symbol: "hourglass")
                ScreenStatTile(value: model.localOnlyCount, label: "Kept on this Mac", symbol: "lock")
            }
            if !config.config.screenCapture.enabled {
                HStack {
                    Label("Screen capture is off", systemImage: "pause.circle").foregroundStyle(.secondary)
                    Button("Open Settings", action: onOpenSettings)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private var sent: some View {
        let days = ScreenSectionText.days(ScreenSectionText.rows(model.sendLog, suggestions: suggestions.mapValues(\.count), redactions: redactions))
        if days.isEmpty {
            Text("Nothing has been sent to the agent yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        ForEach(days) { day in
            VStack(alignment: .leading, spacing: 10) {
                Text(day.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(day.rows.filter(\.hasSuggestions)) { card($0) }
                let quiet = day.rows.filter { !$0.hasSuggestions }
                if !quiet.isEmpty { quietGroup(quiet, key: day.title) }
            }
        }
    }

    private func card(_ row: ScreenSendRow) -> some View {
        let list = suggestions[row.id] ?? []
        return Button { open(batch: row.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(row.suggestions ?? "", systemImage: "sparkles").font(.headline).foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("\(row.time), \(row.items)").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(list.prefix(3)) { s in
                    HStack(spacing: 8) {
                        Image(systemName: ScreenBatchLoader.symbol(s.kind)).foregroundStyle(.secondary).frame(width: 18)
                        Text(s.title).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 8)
                        ScreenChip(text: ScreenBatchText.outcomeShort(s.outcome), symbol: s.outcome.symbol, color: s.outcome.color)
                    }
                }
                if list.count > 3 { Text("and \(list.count - 3) more").font(.caption).foregroundStyle(.secondary) }
            }
            .screenCard(accent: .accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func quietGroup(_ rows: [ScreenSendRow], key: String) -> some View {
        let open = expanded.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { expanded.remove(key) } else { expanded.insert(key) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray").foregroundStyle(.tertiary)
                    Text(ScreenSectionText.quietTitle(rows.count)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider() }
                        Button { self.open(batch: row.id) } label: {
                            HStack(spacing: 8) {
                                Text(row.time).monospacedDigit().foregroundStyle(.secondary)
                                Text(row.items).foregroundStyle(.secondary)
                                Spacer()
                                if let redacted = row.redacted { ScreenChip(text: redacted) }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .screenCard()
            }
        }
    }
}

/// One number with its label and a symbol, in a tile.
struct ScreenStatTile: View {
    let value: Int
    let label: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.formatted()).font(.title2.weight(.semibold).monospacedDigit())
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .screenCard()
    }
}

/// One send as cards: what it carried, every suggestion it produced with what happened to it, and the items.
struct ScreenBatchView: View {
    let batch: ScreenBatch
    var showsBack = true
    var onBack: () -> Void = {}
    var onAccept: (String) -> Void = { _ in }
    var onSkip: (String) -> Void = { _ in }

    @State private var open: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsBack {
                Button { onBack() } label: { Label("Sent to the agent", systemImage: "chevron.left") }
                    .buttonStyle(.link)
            }
            let record = batch.record
            VStack(alignment: .leading, spacing: 4) {
                Text(record.at.formatted(date: .complete, time: .shortened)).font(.title3.weight(.semibold))
                Text(ScreenBatchText.facts(record, redactions: batch.redactions)).font(.callout).foregroundStyle(.secondary)
            }
            .screenCard(accent: batch.suggestions.isEmpty ? nil : .accentColor)
            section(ScreenBatchText.suggestionsTitle(batch.suggestions.count)) {
                if batch.suggestions.isEmpty {
                    Label("Nothing found. The agent read these items and suggested nothing.", systemImage: "tray")
                        .foregroundStyle(.secondary).screenCard()
                }
                ForEach(batch.suggestions) { suggestion(for: $0) }
            }
            section("Items (\(batch.items.count))") {
                if batch.items.isEmpty {
                    Text("This send had no items.").foregroundStyle(.secondary).screenCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(batch.items) { item in
                            if item.id != batch.items.first?.id { Divider() }
                            itemRow(item)
                        }
                    }
                    .screenCard()
                }
            }
            Text("The text shown is the redacted text stored on this Mac, which is what was sent. It is never logged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func suggestion(for s: ScreenBatch.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ScreenBatchLoader.symbol(s.kind)).foregroundStyle(.secondary)
                Text(s.title).fontWeight(.medium)
                Spacer(minLength: 8)
                ScreenChip(text: ScreenBatchText.outcomeShort(s.outcome), symbol: s.outcome.symbol, color: s.outcome.color)
            }
            if !s.quote.isEmpty { Text("\u{201C}\(s.quote)\u{201D}").font(.callout).foregroundStyle(.secondary) }
            HStack {
                Text(ScreenBatchLoader.label(s.kind)).font(.caption).foregroundStyle(.tertiary)
                if let detail = ScreenBatchText.outcomeDetail(s.outcome) { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            if case .pending(let id) = s.outcome {
                HStack {
                    Button("Accept") { onAccept(id) }
                    Button("Skip") { onSkip(id) }
                }
            }
        }
        .screenCard(accent: s.outcome.color == .secondary ? nil : s.outcome.color)
    }

    private func itemRow(_ item: ScreenBatch.Item) -> some View {
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
                .padding(.vertical, 6)
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

    /// "Pending", "Accepted" or "Rejected", for the chip beside a suggestion.
    static func outcomeShort(_ outcome: ScreenBatch.Suggestion.Outcome) -> String {
        switch outcome {
        case .pending: return "Pending"
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        }
    }

    /// What the outcome adds beyond its chip: the task an accepted suggestion became, or why it was rejected.
    static func outcomeDetail(_ outcome: ScreenBatch.Suggestion.Outcome) -> String? {
        switch outcome {
        case .pending: return nil
        case .accepted(let task, let title): return title ?? task.map { "Task \($0)" }
        case .rejected(let note): return note
        }
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
