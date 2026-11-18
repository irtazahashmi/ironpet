import AppKit
import SwiftUI

/// What screen capture stored, for debugging: when, from which app and thread, the text, what the local filter decided and whether it
/// was sent. It is the Captures tab of the Screen section: a timeline of cards, and one card opened with its details. It reads the
/// local database only. Nothing here goes to a model, to MCP or to a log.
struct CaptureInspectorView: View {
    let store: CaptureStore
    /// The item shown in full, or nil for the timeline.
    @Binding var opened: Int64?
    /// Opens the send an item went out in.
    var onOpenBatch: (Int64) -> Void = { _ in }
    @State private var rows: [CaptureStore.InspectRow] = []
    /// The send each item went out in.
    @State private var sends: [Int64: CaptureSendRecord] = [:]
    @State private var filter = "all"
    @State private var search = ""
    /// The item whose unredacted original is shown.
    @State private var revealed: Int64?
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var shown: [CaptureStore.InspectRow] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { ($0.body + " " + $0.threadTitle + " " + $0.appName).lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let row = rows.first(where: { $0.id == opened }) {
                detail(row)
            } else if opened != nil {
                Button { opened = nil } label: { Label("Captures", systemImage: "chevron.left") }.buttonStyle(.link)
                Text("This item is no longer stored.").foregroundStyle(.secondary)
            } else {
                timeline
            }
        }
        .onAppear(perform: reload)
        .onReceive(timer) { _ in reload() }
        .onChange(of: filter) { _ in reload() }
    }

    private func reload() {
        rows = store.inspect(state: filter == "all" ? nil : filter)
        var map: [Int64: CaptureSendRecord] = [:]
        for record in store.sendLog(limit: 1_000).reversed() { for id in record.items { map[id] = record } }
        sends = map
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("State", selection: $filter) {
                    Text("All").tag("all")
                    Text("Waiting for filter").tag("new")
                    Text("Passed").tag("ready")
                    Text("Kept on this Mac").tag("local")
                    Text("Sent").tag("sent")
                }
                .labelsHidden().frame(width: 170)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            }
            if shown.isEmpty {
                Text(rows.isEmpty ? "Nothing has been captured yet." : "No capture matches.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(days(shown), id: \.title) { day in
                VStack(alignment: .leading, spacing: 10) {
                    Text(day.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(day.rows) { card($0) }
                }
            }
        }
    }

    private func days(_ rows: [CaptureStore.InspectRow]) -> [(title: String, rows: [CaptureStore.InspectRow])] {
        var result: [(title: String, rows: [CaptureStore.InspectRow])] = []
        for row in rows {
            let title = ScreenSectionText.dayTitle(row.at, now: Date(), calendar: .current)
            if let last = result.indices.last, result[last].title == title { result[last].rows.append(row) } else { result.append((title, [row])) }
        }
        return result
    }

    private func card(_ row: CaptureStore.InspectRow) -> some View {
        Button { opened = row.id } label: {
            HStack(alignment: .top, spacing: 10) {
                appTile(row)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.threadTitle).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.at.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(row.body.isEmpty ? "The text of this item was dropped." : String(row.body.prefix(120)))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(row.appName).font(.caption).foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        stateChip(row)
                    }
                }
            }
            .screenCard(accent: row.state == "local" ? .orange : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appTile(_ row: CaptureStore.InspectRow) -> some View {
        Image(systemName: Self.symbol(row.appName))
            .frame(width: 28, height: 28)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    static func symbol(_ app: String) -> String {
        switch app.lowercased() {
        case "slack", "discord", "teams", "microsoft teams": return "bubble.left.and.bubble.right"
        case "mail", "outlook": return "envelope"
        case "messages", "whatsapp", "telegram", "signal": return "message"
        case "notes": return "note.text"
        case "calendar": return "calendar"
        default: return "doc.text"
        }
    }

    private func stateChip(_ row: CaptureStore.InspectRow) -> some View {
        let (text, symbol, color): (String, String?, Color) = switch row.state {
        case "new": ("Waiting", "hourglass", .secondary)
        case "ready": ("Passed", "checkmark", .blue)
        case "local": ("Kept on this Mac", "lock", .orange)
        case "sent": ("Sent", "paperplane", .green)
        default: (row.state, nil, .secondary)
        }
        return ScreenChip(text: text, symbol: symbol, color: color)
    }

    // MARK: Opened item

    private func detail(_ row: CaptureStore.InspectRow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { opened = nil; revealed = nil } label: { Label("Captures", systemImage: "chevron.left") }.buttonStyle(.link)
            HStack(alignment: .top, spacing: 12) {
                appTile(row)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.threadTitle).font(.title3.weight(.semibold))
                    Text("\(row.appName), \(row.at.formatted(date: .complete, time: .shortened))").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                stateChip(row)
            }
            .screenCard(accent: row.state == "local" ? .orange : nil)
            VStack(alignment: .leading, spacing: 0) {
                fact("Source", row.url ?? row.threadKey, last: false)
                fact("App", "\(row.appName) (\(row.app))", last: false)
                fact("Kind", "\(row.kind), version \(row.version)" + (row.newMessages > 0 ? ", \(row.newMessages) new messages" : ""), last: false)
                fact("State", Self.stateText(row), last: false)
                fact("Secret check", Self.secretText(row), last: false)
                if let calendar = row.calendar { fact("Calendar score", calendar.formatted(.number.precision(.fractionLength(2))), last: false) }
                if let task = row.task { fact("New-task score", task.formatted(.number.precision(.fractionLength(2))), last: false) }
                fact("Redacted", row.redactions.summary, last: row.sentAt == nil && sends[row.id] == nil)
                if let send = sends[row.id] {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Went out in").font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Button { onOpenBatch(send.id) } label: {
                            Label("\(send.at.formatted(date: .abbreviated, time: .shortened)), \(ScreenSectionText.count(send.items.count, "item"))", systemImage: "paperplane")
                        }
                        .buttonStyle(.link)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                }
            }
            .screenCard()
            Text(revealed == row.id ? "Original text, unredacted" : "Redacted text").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                if revealed == row.id, let original = store.original(of: row.id) {
                    Label("Unredacted. Kept on this Mac until \(original.expires.formatted(date: .omitted, time: .shortened)), never sent.", systemImage: "eye")
                        .font(.caption).foregroundStyle(.orange)
                    Text(original.text.isEmpty ? "The original is empty." : original.text)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                } else {
                    Text(row.body.isEmpty ? "The text of this item was dropped." : row.body)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            .screenCard()
            if !row.redactions.isEmpty || row.originalUntil != nil {
                if let until = row.originalUntil {
                    Button(revealed == row.id ? "Hide original" : "Reveal original") { revealed = revealed == row.id ? nil : row.id }
                    Text("The unredacted text is deleted at \(until.formatted(date: .abbreviated, time: .shortened)). After that only the redacted text remains.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The unredacted original was deleted after 24 hours. Only the redacted text remains.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.body, forType: .string)
                }
                Button("Show database in Finder") {
                    if let path = store.database.path { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                Text(value).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            if !last { Divider() }
        }
    }

    /// Where the item is in the pipeline, with the reason when the filter gave one.
    static func stateText(_ row: CaptureStore.InspectRow) -> String {
        let name = ["new": "Waiting for the filter", "ready": "Passed the filter, waiting to be sent", "local": "Kept on this Mac", "sent": "Sent to the agent"][row.state] ?? row.state
        guard let reason = row.reason, !reason.isEmpty else { return name }
        return "\(name). \(reason.prefix(1).uppercased() + reason.dropFirst())"
    }

    /// The secret score the model gave the text, or that no model has looked at it.
    static func secretText(_ row: CaptureStore.InspectRow) -> String {
        guard let secret = row.secret else { return CaptureDecisionFilter.notCheckedLabel(state: row.state, secret: nil) ?? "Not checked yet" }
        let score = secret.formatted(.number.precision(.fractionLength(2)))
        return row.reason == CaptureDecisionFilter.flaggedReason ? "Score \(score), flagged" : "Score \(score), clear"
    }
}
