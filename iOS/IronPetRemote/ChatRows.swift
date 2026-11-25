import IronPetKit
import SwiftUI
import UIKit

// The rows of the transcript, drawn the way the Mac's `ChatView`, `Markdown`, `SystemNoticeRow` and `ToolSteps` draw them. Sizes
// are the Mac's point sizes scaled by `ChatMetrics.scale`, so Dynamic Type applies on the phone. PARITY.md lists what differs.

enum ChatMetrics {
    /// The Mac's reply font is 13.5 pt. The phone's is 15 pt before Dynamic Type, which reads better at arm's length.
    static let macBody: CGFloat = 13.5
    static let phoneBody: CGFloat = 15
    static var scale: CGFloat { phoneBody / macBody }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: Markdown

/// A reply's markdown as views: headings, paragraphs, lists, quotes, code blocks, tables and rules, with the Mac's sizes and spacing.
struct MarkdownBody: View {
    let text: String
    /// The highlights of Find in chat. Nil outside a search.
    var find: RemoteChatFind.RowHighlight?
    @Environment(\.openFilePath) private var openFilePath
    private var links: Bool { openFilePath != nil }
    @Environment(\.macAccent) private var macAccent
    @Environment(\.selectingText) private var selecting
    @ChatScale(.body) private var scale

    var body: some View {
        // The reply is SwiftUI text, which a long press leaves to the message menu. "Select text" in that menu swaps in text views that select.
        if selecting?.wrappedValue == true { selectableBody } else { plainBody }
    }

    private var selectableBody: some View {
        let blocks = ChatMarkdown.parse(text)
        let starts = find == nil ? [] : blocks.reduce(into: [0]) { $0.append($0.last! + ChatMarkdown.segments(of: $1).count) }
        let allChunks = chunks(of: blocks, starts: starts)
        let firstText = allChunks.firstIndex { if case .block = $0 { return false } else { return true } }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(allChunks.enumerated()), id: \.offset) { index, chunk in
                switch chunk {
                case .run(let pieces):
                    // Consecutive headings, paragraphs and list items are one text view, so a selection can span them.
                    SelectableText(pieces: pieces, size: ChatMetrics.macBody * scale, accent: macAccent, takesSelection: index == firstText)
                        .padding(.top, pieces.first.map { if case .heading = $0.style { return 2 } else { return 0 } } ?? 0)
                        .padding(.bottom, -SelectableTextBuilder.lineSpacing)
                case .quote(let piece):
                    SelectableText(pieces: [piece], size: ChatMetrics.macBody * scale, accent: macAccent, takesSelection: index == firstText)
                        .padding(.bottom, -SelectableTextBuilder.lineSpacing)
                        .padding(.leading, 11)
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3) }
                case .block(let block, let segment):
                    view(for: block, segment: segment)
                }
            }
        }
    }

    private enum Chunk {
        case run([SelectablePiece])
        case quote(SelectablePiece)
        case block(ChatMarkdown.Block, segment: Int)
    }

    private func chunks(of blocks: [ChatMarkdown.Block], starts: [Int]) -> [Chunk] {
        var result: [Chunk] = []
        var run: [SelectablePiece] = []
        func flush() { if !run.isEmpty { result.append(.run(run)); run = [] } }
        func styled(_ text: String, segment: Int) -> AttributedString {
            ChatMarkdown.inline(text).linkingFilePaths(links).findHighlighted(segment: segment, find: find)
        }
        for (index, block) in blocks.enumerated() {
            let segment = starts.isEmpty ? 0 : starts[index]
            switch block {
            case .heading(let level, let text):
                let size: CGFloat = (level == 1 ? 17 : level == 2 ? 15.5 : 14) * scale
                run.append(SelectablePiece(text: styled(text, segment: segment), style: .heading(size: size, bold: level <= 2)))
            case .paragraph(let text):
                run.append(SelectablePiece(text: styled(text, segment: segment), style: .body))
            case .list(_, let items):
                for (offset, item) in items.enumerated() {
                    let task = item.task
                    let marker: SelectablePiece.Marker = task.map { .task(done: $0.done) }
                        ?? (item.marker.first?.isNumber == true ? .number(item.marker) : .bullet(item.indent == 0 ? "•" : "◦"))
                    run.append(SelectablePiece(text: styled(task?.text ?? item.text, segment: segment + offset), style: .listItem(indent: item.indent, marker: marker)))
                }
            case .quote(let text):
                flush()
                result.append(.quote(SelectablePiece(text: styled(text, segment: segment), style: .quote)))
            case .code, .table, .rule:
                flush()
                result.append(.block(block, segment: segment))
            }
        }
        flush()
        return result
    }

    private var plainBody: some View {
        let blocks = ChatMarkdown.parse(text)
        // Each block draws as many pieces of text as `ChatMarkdown.segments` lists, and a match names its piece by that numbering.
        let starts = find == nil ? [] : blocks.reduce(into: [0]) { $0.append($0.last! + ChatMarkdown.segments(of: $1).count) }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, segment: starts.isEmpty ? 0 : starts[index])
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: ChatMarkdown.Block, segment: Int) -> some View {
        let size = ChatMetrics.macBody * scale
        switch block {
        case .heading(let level, let text):
            let heading: CGFloat = (level == 1 ? 17 : level == 2 ? 15.5 : 14) * scale
            Text(ChatMarkdown.inline(text).linkingFilePaths(links).findHighlighted(segment: segment, find: find))
                .font(.system(size: heading, weight: level <= 2 ? .bold : .semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            Text(ChatMarkdown.inline(text).linkingFilePaths(links).findHighlighted(segment: segment, find: find)).font(.system(size: size)).lineSpacing(2)
        case .quote(let text):
            Text(ChatMarkdown.inline(text).linkingFilePaths(links).findHighlighted(segment: segment, find: find)).font(.system(size: size)).lineSpacing(2).foregroundStyle(.secondary)
                .padding(.leading, 11)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .list(_, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in ListRow(item: item, size: size, segment: segment + index, find: find) }
            }
        case .code(let language, let code, _):
            let plain = CodeBlock(language: language, code: code, size: 12 * scale, scale: scale, segment: segment, find: ChatMarkdown.segments(of: block).isEmpty ? nil : find)
            if let diagram = ChatMarkdown.mermaidSource(of: block) {
                MermaidBlock(code: diagram) { plain }
            } else {
                plain
            }
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, size: size, segment: segment, find: find)
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
        }
    }
}

private struct ListRow: View {
    let item: ChatMarkdown.ListItem
    let size: CGFloat
    var segment = 0
    var find: RemoteChatFind.RowHighlight?
    @Environment(\.openFilePath) private var openFilePath
    private var links: Bool { openFilePath != nil }

    var body: some View {
        let task = item.task
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker(task: task).foregroundStyle(.secondary).frame(minWidth: item.marker.first?.isNumber == true && task == nil ? 18 : 10, alignment: .trailing)
            Text(ChatMarkdown.inline(task?.text ?? item.text).linkingFilePaths(links).findHighlighted(segment: segment, find: find)).font(.system(size: size)).lineSpacing(2)
        }
        .padding(.leading, CGFloat(item.indent) * 14)
    }

    @ViewBuilder
    private func marker(task: (done: Bool, text: String)?) -> some View {
        if let task {
            Image(systemName: task.done ? "checkmark.square.fill" : "square").font(.system(size: size))
        } else if item.marker.first?.isNumber == true {
            Text(item.marker).font(.system(size: size).monospacedDigit())
        } else {
            Text(item.indent == 0 ? "•" : "◦").font(.system(size: size))
        }
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    let size: CGFloat
    let scale: CGFloat
    var segment = 0
    var find: RemoteChatFind.RowHighlight?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.system(size: 10.5 * scale, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? SharedSymbols.allow : SharedSymbols.copy).font(.system(size: 10.5 * scale))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityIdentifier("copy-code")
            }
            .padding(.horizontal, 10).padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(AttributedString(code).findHighlighted(segment: segment, find: find)).font(.system(size: size, design: .monospaced)).fixedSize()
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityIdentifier("code-block")
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    let size: CGFloat
    var segment = 0
    var find: RemoteChatFind.RowHighlight?
    @Environment(\.openFilePath) private var openFilePath
    private var links: Bool { openFilePath != nil }

    var body: some View {
        // The cells number from `segment`: the header first, then each row.
        let rowStarts = rows.reduce(into: [segment + header.count]) { $0.append($0.last! + $1.count) }
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        Text(ChatMarkdown.inline(cell).linkingFilePaths(links).findHighlighted(segment: segment + column, find: find)).fontWeight(.semibold)
                    }
                }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).gridCellColumns(max(header.count, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            Text(ChatMarkdown.inline(cell).linkingFilePaths(links).findHighlighted(segment: rowStarts[r] + column, find: find))
                        }
                    }
                }
            }
            .font(.system(size: size))
            .padding(10)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("table-block")
    }
}

// MARK: Messages

/// The quoted original: sender and the first two lines. On a user bubble it is white on a lighter fill.
struct ReplyQuote: View {
    @Environment(\.macAccent) private var macAccent
    let reply: RemoteChatReply
    var onUser = false
    @ChatScale(.caption1) private var scale

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(onUser ? Color.white.opacity(0.8) : macAccent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.sender).font(.system(size: 11 * scale, weight: .semibold))
                // Only the start fits in two lines, and a quoted paste should not be laid out in full.
                Text(reply.text.prefix(300)).font(.system(size: 11.5 * scale)).lineLimit(2).truncationMode(.tail)
            }
            .foregroundStyle(onUser ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        .background(onUser ? Color.white.opacity(0.18) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("reply-quote")
    }
}

/// Where a message came from when it was not typed on the Mac, as the Mac's badge names it.
struct OriginBadge {
    let symbol: String
    let label: String

    init?(origin: String?) {
        switch origin {
        case "telegram": self.init(symbol: SharedSymbols.sourceTelegram, label: "Telegram")
        case "automation": self.init(symbol: SharedSymbols.sourceAutomation, label: "Automation")
        case "job": self.init(symbol: SharedSymbols.sourceJob, label: "Background job")
        case "voice": self.init(symbol: SharedSymbols.sourceVoice, label: "Voice")
        case "ios": self.init(symbol: SharedSymbols.sourceIPhone, label: "iPhone")
        default: return nil
        }
    }

    private init(symbol: String, label: String) { self.symbol = symbol; self.label = label }
}

/// What a message the Mac has not confirmed looks like. The state shows on the bubble, so no row is added and nothing moves.
struct OutgoingLook: Equatable {
    let state: OutgoingMessage.State
    /// A voice message whose text has not arrived. Its bubble says "Transcribing…" in place of a dimmed look.
    let transcribing: Bool
    /// The message was saved on the phone while the Mac was out of reach, so it can be deleted.
    let queued: Bool

    init(_ message: OutgoingMessage) {
        state = message.state
        transcribing = message.isTranscribing
        queued = message.queuedAt != nil
    }

    static let dimmedOpacity: Double = 0.55
    /// Solid, so the white text reads the same in light and dark mode.
    static let failedFill = Color(red: 0.76, green: 0.17, blue: 0.19)

    var opacity: Double {
        switch state {
        case .waiting: Self.dimmedOpacity
        case .sending, .sent: transcribing ? 1 : Self.dimmedOpacity
        case .failed: 1
        }
    }

    var showsClock: Bool { state == .waiting }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var failureReason: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    var canDelete: Bool { state == .waiting || (isFailed && queued) }

    /// Read after the message text by VoiceOver. Empty for a message in flight that has a visible "Transcribing…".
    var accessibilityValue: String {
        switch state {
        case .waiting: "Waiting to send"
        case .sending, .sent: transcribing ? "" : "Sending"
        case .failed(let reason): "Not sent. \(reason)"
        }
    }
}

/// The dim, the clock and the retry button of an unconfirmed message. All of it is overlay, so the layout is the same in every state.
struct OutgoingMarks: ViewModifier {
    let look: OutgoingLook?
    var onRetry: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .opacity(look?.opacity ?? 1)
            .overlay(alignment: .bottomLeading) {
                if look?.showsClock == true {
                    Image(systemName: "clock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color(.systemBackground)))
                        .offset(x: -6, y: 6)
                        // The bubble's accessibility value already says it, so VoiceOver reads the state once.
                        .accessibilityHidden(true)
                }
            }
            // Beside the bubble, in the space the row keeps free on its leading side, so it never covers the source label or the time below.
            .overlay(alignment: .leading) {
                if look?.isFailed == true, let onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(OutgoingLook.failedFill))
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            // The visible circle is 26 pt. The tap area is 44 pt.
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -48)
                    .accessibilityLabel("Retry sending")
                    .accessibilityIdentifier("outgoing-retry")
                }
            }
    }
}

/// Your message: an accent bubble with a small bottom trailing corner, the time and source under it, and "Show more" on a long one.
struct UserBubble: View {
    @Environment(\.macAccent) private var macAccent
    let item: RemoteChatItem
    let text: String
    var expanded = false
    var onToggleExpand: () -> Void = {}
    var find: RemoteChatFind.RowHighlight?
    /// The send state of a message the Mac has not confirmed. Nil once it has.
    var outgoing: OutgoingLook?
    var onRetry: (() -> Void)?
    /// The "Delivered" mark of the last confirmed message. It sits on the row with the source and the time.
    var status: AnyView?
    @Environment(\.openFilePath) private var openFilePath
    private var links: Bool { openFilePath != nil }
    @ChatScale(.body) private var scale

    var body: some View {
        let preview = ChatMessageCollapse.preview(of: text)
        let shown = expanded ? text : (preview?.text ?? text)
        VStack(alignment: .trailing, spacing: 3) {
            VStack(alignment: .leading, spacing: 6) {
                if let reply = item.reply { ReplyQuote(reply: reply, onUser: true) }
                Text(Self.linked(shown).linkingFilePaths(links).findHighlighted(segment: 0, find: find)).font(.system(size: ChatMetrics.macBody * scale)).foregroundStyle(.white).tint(.white)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(outgoing?.isFailed == true ? OutgoingLook.failedFill : macAccent,
                        in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityValue(outgoing?.accessibilityValue ?? "")
            .accessibilityIdentifier("bubble-\(item.id)")
            .modifier(OutgoingMarks(look: outgoing, onRetry: onRetry))
            // The retry button sits beside the bubble. The rows below it must not take its taps.
            .zIndex(1)
            if let preview {
                Button(action: onToggleExpand) {
                    Text(expanded ? "Show less" : "Show more · \(preview.hiddenCharacters.formatted()) characters").font(.system(size: 11 * scale))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityIdentifier("collapse-toggle-\(item.id)")
            }
            HStack(spacing: 4) {
                if let badge = OriginBadge(origin: item.origin) {
                    Image(systemName: badge.symbol).font(.system(size: 9 * scale))
                    Text(badge.label).font(.system(size: 10 * scale))
                }
                if let date = item.date { Text(ChatMetrics.timeFormatter.string(from: date)).font(.system(size: 10 * scale)) }
                if let status { status.padding(.leading, 4) }
            }
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Links in a message are tappable. A plain message has no markdown, so it is not parsed as markdown.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in linkDetector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            // Map the match by position, so a URL that appears twice links both times.
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

/// What a reply needs to be read aloud: whether it is being read now, and the button action. The speaker button and the long-press
/// menu item share it.
struct ReadAloud {
    var active: Bool
    var toggle: () -> Void

    @MainActor
    init(item: RemoteChatItem, voice: VoiceModel) {
        active = voice.readingItem == item.id
        toggle = { Task { await voice.toggleReading(item.id) } }
    }

    init(active: Bool, toggle: @escaping () -> Void) {
        self.active = active
        self.toggle = toggle
    }
}

/// The agent's reply: the pet's face beside the markdown, with the time under it and a speaker button that reads it aloud.
struct AssistantBubble: View {
    let item: RemoteChatItem
    let text: String
    var avatar: CGImage?
    var readAloud: ReadAloud?
    var find: RemoteChatFind.RowHighlight?
    @ChatScale(.caption1) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PetAvatar(image: avatar, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                MarkdownBody(text: text, find: find)
                    .padding(.top, 3)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bubble-\(item.id)")
                HStack(spacing: 8) {
                    if let date = item.date {
                        Text(ChatMetrics.timeFormatter.string(from: date)).font(.system(size: 10 * scale)).foregroundStyle(.tertiary)
                    }
                    if let readAloud { SpeakButton(readAloud: readAloud, scale: scale) }
                }
            }
            Spacer(minLength: 30)
        }
    }
}

/// Reads a reply aloud, or stops it. Shows Stop while its reply is being read.
private struct SpeakButton: View {
    @Environment(\.macAccent) private var macAccent
    let readAloud: ReadAloud
    let scale: CGFloat

    var body: some View {
        let label = readAloud.active ? "Stop reading" : "Read aloud"
        Button(action: readAloud.toggle) {
            Image(systemName: readAloud.active ? SharedSymbols.stopSpeaking : SharedSymbols.speak)
                .font(.system(size: 12 * scale))
                .foregroundStyle(readAloud.active ? AnyShapeStyle(macAccent) : AnyShapeStyle(.tertiary))
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("speak-button")
    }
}

/// The pet's first idle frame, cropped to the face, as the Mac's chat avatar.
struct PetAvatar: View {
    let image: CGImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: SharedSymbols.pet).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.06), in: Circle())
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    /// The crop the Mac uses on the first idle frame.
    static func face(of atlas: Atlas?) -> CGImage? {
        atlas?.frame(.idle, 0)?.cropping(to: CGRect(x: 34, y: 36, width: 124, height: 112))
    }
}

// MARK: Tools, notices, errors

struct ToolStepsRow: View {
    let steps: [RemoteChatItem]
    @State private var expanded = false
    @ChatScale(.caption1) private var scale

    var body: some View {
        ChatSystemRow(expanded: expanded, scale: scale, identifier: "tool-steps-\(steps[0].id)",
                      label: Text(ChatMarkdown.inline(ChatToolSteps.header(steps, expanded: expanded))),
                      toggle: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } },
                      icon: { ChatToolRunIcon(ChatToolSteps.state(steps)) },
                      detail: {
            ChatStepList(count: steps.count) { index in
                let step = steps[index]
                HStack(spacing: 6) {
                    ChatStepIcon(step.ok)
                    Text(ChatMarkdown.inline(step.text ?? "")).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5 * scale)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .accessibilityIdentifier("tool-step-\(step.id)")
            }
        })
    }
}

/// A system notice: one muted line naming its source. A tap shows the rest of the text. It draws through the same
/// `ChatSystemRow` as the tool steps, as the Mac does.
struct NoticeRow: View {
    let notice: ChatNotice
    @State private var expanded = false
    @ChatScale(.caption1) private var scale

    var body: some View {
        ChatSystemRow(expanded: expanded, canExpand: !notice.detail.isEmpty, scale: scale, identifier: "notice-label",
                      label: Text(notice.label),
                      toggle: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } },
                      icon: { Image(systemName: SharedSymbols.settings) },
                      detail: {
            Text(ChatMarkdown.inline(notice.detail)).font(.system(size: 12 * scale)).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(SharedTheme.card, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 2)
                .accessibilityIdentifier("notice-detail")
        })
    }
}

/// An error in the transcript: red text on a light red card.
struct ErrorRow: View {
    let text: String
    @ChatScale(.caption1) private var scale

    var body: some View {
        Label(text, systemImage: SharedSymbols.warning).font(.system(size: 12 * scale)).foregroundStyle(.red)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Working

/// Shown while the agent works: the pet's face, a spinner and how long the turn has run. The row has the same size from the first
/// frame. The time has its own slot beside the spinner, empty until the turn start arrives.
struct TypingRow: View {
    let started: Date?
    var avatar: CGImage?
    @ChatScale(.caption1) private var scale

    var body: some View {
        HStack(spacing: 8) {
            PetAvatar(image: avatar, size: 24)
            ProgressView().controlSize(.small).frame(width: 20, height: 20)
            TimelineView(.periodic(from: started ?? Date(), by: 1)) { context in
                Text(started.map { Self.format(context.date.timeIntervalSince($0)) } ?? "")
                    .font(.system(size: 10 * scale)).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 64 * scale, height: 16 * scale, alignment: .leading)
            .accessibilityIdentifier("elapsed")
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working")
        .accessibilityIdentifier("running-row")
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

/// "Jump to latest", shown over the transcript when new content arrived while the reader was scrolled up.
struct JumpToLatestButton: View {
    let action: () -> Void
    @ChatScale(.caption1) private var scale

    var body: some View {
        Button(action: action) {
            Label("Jump to latest", systemImage: SharedSymbols.jumpToLatest)
                .font(.system(size: 11.5 * scale, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .chromeGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jump to latest")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("jump-to-latest")
    }
}
