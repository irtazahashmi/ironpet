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
    @ScaledMetric(relativeTo: .body) private var scale = ChatMetrics.scale

    var body: some View {
        let blocks = ChatMarkdown.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: ChatMarkdown.Block) -> some View {
        let size = ChatMetrics.macBody * scale
        switch block {
        case .heading(let level, let text):
            let heading: CGFloat = (level == 1 ? 17 : level == 2 ? 15.5 : 14) * scale
            Text(ChatMarkdown.inline(text))
                .font(.system(size: heading, weight: level <= 2 ? .bold : .semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            Text(ChatMarkdown.inline(text)).font(.system(size: size)).lineSpacing(2)
        case .quote(let text):
            Text(ChatMarkdown.inline(text)).font(.system(size: size)).lineSpacing(2).foregroundStyle(.secondary)
                .padding(.leading, 11)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .list(_, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in ListRow(item: item, size: size) }
            }
        case .code(let language, let code, _):
            CodeBlock(language: language, code: code, size: 12 * scale)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, size: size)
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
        }
    }
}

private struct ListRow: View {
    let item: ChatMarkdown.ListItem
    let size: CGFloat

    var body: some View {
        let task = item.task
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker(task: task).foregroundStyle(.secondary).frame(minWidth: item.marker.first?.isNumber == true && task == nil ? 18 : 10, alignment: .trailing)
            Text(ChatMarkdown.inline(task?.text ?? item.text)).font(.system(size: size)).lineSpacing(2)
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
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.system(size: 10.5 * ChatMetrics.scale, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5 * ChatMetrics.scale))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityIdentifier("copy-code")
            }
            .padding(.horizontal, 10).padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: size, design: .monospaced)).fixedSize()
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in Text(ChatMarkdown.inline(cell)).fontWeight(.semibold) }
                }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).gridCellColumns(max(header.count, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(ChatMarkdown.inline(cell)) }
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
    let reply: RemoteChatReply
    var onUser = false
    @ScaledMetric(relativeTo: .caption) private var scale = ChatMetrics.scale

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(onUser ? Color.white.opacity(0.8) : Color.accentColor).frame(width: 3)
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
        case "telegram": self.init(symbol: "paperplane.fill", label: "Telegram")
        case "automation": self.init(symbol: "clock.arrow.circlepath", label: "Automation")
        case "job": self.init(symbol: "shippingbox.fill", label: "Background job")
        case "voice": self.init(symbol: "mic.fill", label: "Voice")
        case "ios": self.init(symbol: "iphone", label: "iPhone")
        default: return nil
        }
    }

    private init(symbol: String, label: String) { self.symbol = symbol; self.label = label }
}

/// Your message: an accent bubble with a small bottom trailing corner, the time and source under it, and "Show more" on a long one.
struct UserBubble: View {
    let item: RemoteChatItem
    let text: String
    var expanded = false
    var onToggleExpand: () -> Void = {}
    @ScaledMetric(relativeTo: .body) private var scale = ChatMetrics.scale

    var body: some View {
        let preview = ChatMessageCollapse.preview(of: text)
        let shown = expanded ? text : (preview?.text ?? text)
        VStack(alignment: .trailing, spacing: 3) {
            VStack(alignment: .leading, spacing: 6) {
                if let reply = item.reply { ReplyQuote(reply: reply, onUser: true) }
                Text(Self.linked(shown)).font(.system(size: ChatMetrics.macBody * scale)).foregroundStyle(.white).tint(.white)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.accentColor, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("bubble-\(item.id)")
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
            }
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
    }

    /// Links in a message are tappable. A plain message has no markdown, so it is not parsed as markdown.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let url = match.url, let range = Range(match.range, in: text), let target = result.range(of: text[range]) else { continue }
            result[target].link = url
        }
        return result
    }
}

/// The agent's reply: the pet's face beside the markdown, with the time under it.
struct AssistantBubble: View {
    let item: RemoteChatItem
    let text: String
    var avatar: CGImage?
    @ScaledMetric(relativeTo: .caption) private var scale = ChatMetrics.scale

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PetAvatar(image: avatar, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                MarkdownBody(text: text)
                    .padding(.top, 3)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bubble-\(item.id)")
                if let date = item.date {
                    Text(ChatMetrics.timeFormatter.string(from: date)).font(.system(size: 10 * scale)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 30)
        }
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
                Image(systemName: "pawprint.fill").foregroundStyle(.secondary)
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

/// A run of tool steps folded into one line ("Ran 3 commands, read 2 files"), which expands to one line per step.
struct ToolStepsRow: View {
    let steps: [RemoteChatItem]
    @State private var expanded = false
    @ScaledMetric(relativeTo: .caption) private var scale = ChatMetrics.scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    headerIcon
                    Text(ChatToolSteps.header(steps, expanded: expanded)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.system(size: 9 * scale, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0)).opacity(expanded ? 1 : 0.6)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5 * scale))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-steps-\(steps[0].id)")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
                        HStack(spacing: 6) {
                            icon(step.ok)
                            Text(ChatMarkdown.inline(step.text ?? "")).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5 * scale)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .accessibilityIdentifier("tool-step-\(step.id)")
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 32)
    }

    @ViewBuilder
    private var headerIcon: some View {
        switch ChatToolSteps.state(steps) {
        case .running: icon(nil)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func icon(_ ok: Bool?) -> some View {
        switch ok {
        case nil: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// A system notice: one muted line naming its source. A tap shows the rest of the text.
struct NoticeRow: View {
    let notice: ChatNotice
    @State private var expanded = false
    @ScaledMetric(relativeTo: .caption) private var scale = ChatMetrics.scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if !notice.detail.isEmpty { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape").font(.system(size: 10 * scale))
                    Text(notice.label).font(.system(size: 11.5 * scale))
                    if !notice.detail.isEmpty { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8 * scale, weight: .bold)) }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notice-label")
            if expanded {
                Text(ChatMarkdown.inline(notice.detail)).font(.system(size: 12 * scale)).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("notice-detail")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An error in the transcript: red text on a light red card.
struct ErrorRow: View {
    let text: String
    @ScaledMetric(relativeTo: .caption) private var scale = ChatMetrics.scale

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12 * scale)).foregroundStyle(.red)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Working

/// Shown while the agent works: the pet's face, three pulsing dots and how long the turn has run.
struct TypingRow: View {
    let started: Date?
    var avatar: CGImage?
    @ScaledMetric(relativeTo: .caption) private var scale = ChatMetrics.scale

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PetAvatar(image: avatar, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                PulsingDots()
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                if let started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.format(context.date.timeIntervalSince(started))).font(.system(size: 10 * scale)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .accessibilityIdentifier("elapsed")
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working")
        .accessibilityIdentifier("running-row")
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

/// Three dots that pulse in turn. Reduce Motion holds them still.
struct PulsingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 0.6 : (on ? 1 : 0.35))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true).delay(Double(index) * 0.2), value: on)
            }
        }
        .frame(width: 30, height: 6)
        .onAppear { on = true }
        .accessibilityHidden(true)
    }
}

/// "Jump to latest", shown over the transcript when new content arrived while the reader was scrolled up.
struct JumpToLatestButton: View {
    let action: () -> Void
    @ScaledMetric(relativeTo: .caption) private var scale = ChatMetrics.scale

    var body: some View {
        Button(action: action) {
            Label("Jump to latest", systemImage: "arrow.down")
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
