import IronPetKit
import SwiftUI

/// The capsule above the message field. It opens the Mac's background work list as a sheet.
struct BackgroundCapsuleRow: View {
    let model: ChatModel
    @State private var open = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button { open = true; model.openBackground() } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    Text(model.capsule.label).font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(tint.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Background work, \(model.capsule.label)")
            .accessibilityIdentifier("background-capsule")
        }
        .padding(.horizontal)
        .sheet(isPresented: $open) { BackgroundWorkSheet(model: model) }
    }

    private var symbol: String {
        switch model.capsule {
        case .idle: return "square.stack.3d.up"
        case .running: return "arrow.triangle.2.circlepath"
        case .waiting: return "hand.raised.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch model.capsule {
        case .idle: return .secondary
        case .running: return .accentColor
        case .waiting: return .orange
        case .failed: return .red
        }
    }
}

struct BackgroundWorkSheet: View {
    let model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []

    var body: some View {
        BackgroundWorkContent(items: model.background, expanded: $expanded,
                              clear: { Task { await model.clearFinishedBackground() } },
                              stop: { id in Task { await model.stopBackground(id) } },
                              done: { dismiss() })
            .presentationDetents([.medium, .large])
    }
}

/// The sheet's body, without the model, so a preview can draw it from sample rows.
struct BackgroundWorkContent: View {
    let items: [RemoteBackgroundItem]
    @Binding var expanded: Set<String>
    var clear: () -> Void = {}
    var stop: (String) -> Void = { _ in }
    var done: () -> Void = {}

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("Nothing ran in the background", systemImage: "square.stack.3d.up")
                } else {
                    List(items) { item in
                        BackgroundSheetRow(item: item, isOpen: expanded.contains(item.id),
                                           toggle: { if !expanded.insert(item.id).inserted { expanded.remove(item.id) } },
                                           stop: { stop(item.id) })
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Background work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if items.contains(where: \.isFinished) { Button("Clear finished", action: clear) }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done", action: done) }
            }
        }
    }
}

private struct BackgroundSheetRow: View {
    let item: RemoteBackgroundItem
    let isOpen: Bool
    let toggle: () -> Void
    let stop: () -> Void

    private var subtitle: String? {
        BackgroundWorkStyle.subtitle(state: item.state, now: item.now, waitingFor: item.waitingFor, result: item.result, steps: item.steps, kind: item.kind)
    }

    private var subtitleColor: Color {
        switch item.state {
        case "done": return .green
        case "failed": return .red
        case "waiting": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: BackgroundWorkStyle.kindSymbol(item.kind))
                        .frame(width: 30, height: 30)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(subtitleColor).lineLimit(isOpen ? 3 : 1) }
                    }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(BackgroundWorkStyle.elapsed((item.endedAt ?? context.date).timeIntervalSince(item.startedAt)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("background-row-\(item.id)")
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if !item.lines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(item.lines.suffix(8).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if item.stoppable {
                        Button(role: .destructive, action: stop) { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.bordered)
                    } else if !item.isFinished, let hint = item.stopHint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }
}
