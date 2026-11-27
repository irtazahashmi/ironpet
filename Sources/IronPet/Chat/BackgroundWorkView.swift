import AppKit
import IronPetCore
import IronPetKit
import SwiftUI

/// The capsule above the message field. It shows what runs in the background and opens the list as a popover.
struct BackgroundCapsuleButton: View {
    @ObservedObject var session: ChatViewModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(open ? Color.white : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(open ? Color.accentColor : tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.45)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Background work, \(label)")
        .accessibilityIdentifier("background-capsule")
        .popover(isPresented: $open, arrowEdge: .top) {
            BackgroundPopover(session: session)
        }
        .onChange(of: open) { _, isOpen in if isOpen { session.openBackground() } }
    }

    private var label: String {
        switch session.backgroundIndicator {
        case .idle: return "Nothing running"
        case .running(let count): return "\(count) running"
        case .waiting(let count): return "\(count) waiting for approval"
        case .failed(let count): return "\(count) failed"
        }
    }

    private var symbol: String {
        switch session.backgroundIndicator {
        case .idle: return "square.stack.3d.up"
        case .running: return "arrow.triangle.2.circlepath"
        case .waiting: return "hand.raised.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch session.backgroundIndicator {
        case .idle: return .secondary
        case .running: return .accentColor
        case .waiting: return .orange
        case .failed: return .red
        }
    }
}

/// The popover: one row per item, each opening in place.
struct BackgroundPopover: View {
    @ObservedObject var session: ChatViewModel
    @State private var expanded: Set<String>

    init(session: ChatViewModel, expanded: Set<String> = []) {
        self.session = session
        _expanded = State(initialValue: expanded)
    }

    private var summary: String {
        let running = session.background.filter { $0.state == .running }.count
        let waiting = session.background.filter { $0.state == .waiting }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: ", ")
    }

    private var hasFinished: Bool { session.background.contains { $0.state.isFinished } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Background work").font(.system(size: 13, weight: .semibold))
                if !summary.isEmpty { Text(summary).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                if hasFinished {
                    Button("Clear finished") { session.clearFinishedBackground() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .pointerCursor()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if session.background.isEmpty {
                Text(session.backgroundIdleSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(session.background) { item in
                            BackgroundRow(item: item, isOpen: expanded.contains(item.id),
                                          toggle: { if !expanded.insert(item.id).inserted { expanded.remove(item.id) } },
                                          stop: { session.stopBackground(item.id) })
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 380)
    }
}

private struct BackgroundRow: View {
    let item: BackgroundItem
    let isOpen: Bool
    let toggle: () -> Void
    let stop: () -> Void

    private var subtitle: String? {
        BackgroundWorkStyle.subtitle(state: item.state.rawValue, now: item.now, waitingFor: item.waitingFor, result: item.result, steps: item.steps,
                                     kind: item.kind.rawValue)
    }

    private var subtitleColor: Color {
        switch item.state {
        case .done: return .green
        case .failed: return .red
        case .waiting: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: BackgroundWorkStyle.kindSymbol(item.kind.rawValue))
                        .font(.system(size: 12))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(subtitleColor).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(BackgroundWorkStyle.elapsed(item.elapsed(at: context.date)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    stateGlyph
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityIdentifier("background-row-\(item.id)")
            if isOpen { details }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isOpen ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var stateGlyph: some View {
        switch item.state {
        case .running: ProgressView().controlSize(.mini)
        case .waiting: Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.system(size: 11))
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 12))
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.system(size: 12))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let waiting = item.waitingFor {
                Text("Waiting for: \(waiting)").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if !item.lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(item.lines.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: item.kind == .shell || item.kind == .monitor ? .monospaced : .default))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        Divider()
                    }
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if let path = item.outputFile {
                    Button("Open output file") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11)).pointerCursor()
                }
                Spacer()
                if item.stoppable {
                    Button(action: stop) { Label("Stop", systemImage: "stop.fill").font(.system(size: 11)) }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red).pointerCursor()
                } else if !item.state.isFinished, let hint = item.stopHint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 36)
    }
}
