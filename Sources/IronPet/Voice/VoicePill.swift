import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import IronPetKit
import SwiftUI

/// What a spoken message shows by the pet: the microphone while it listens, then "Got it" while the recording is
/// transcribed, and a button to discard it. The pet itself shows that it is listening (`SpokenMessageRecorder.mood`).
struct VoicePillView: View {
    @ObservedObject var recorder: SpokenMessageRecorder
    var petName: String
    var onEnd: () -> Void

    private var state: SpokenMessageRecorder.State { recorder.state }
    var title: String { state.title }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .listening ? Color.red : Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let heard = recorder.heard {
                    Text(heard)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onEnd) {
                Image(systemName: SharedSymbols.deny)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("End voice mode (Esc)")
            .accessibilityLabel("End voice mode")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 280)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spoken message: \(title)")
    }
}

extension SpokenMessageRecorder.State {
    /// The state in a few words, for the pill.
    var title: String {
        switch self {
        case .idle: return "Voice"
        case .listening: return "Listening…"
        case .transcribing: return "Got it…"
        case .waiting: return "Waiting for the reply…"
        }
    }

    var symbol: String {
        switch self {
        case .idle, .listening: return SharedSymbols.microphoneActive
        case .transcribing, .waiting: return "ellipsis"
        }
    }
}

/// Bars that follow the microphone's level, as tall as the frame. With Reduce Motion on they show one steady level.
struct VoiceLevelMeter: View {
    let levels: LevelBuffer
    var count = 5
    var barWidth: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                bars(Array(repeating: 0.5, count: count))
            } else {
                TimelineView(.animation) { timeline in
                    let _ = timeline.date
                    bars(levels.recent(count).bars)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ values: [Float]) -> some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: barWidth * 0.75) {
                ForEach(values.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: barWidth, height: max(barWidth, CGFloat(values[index]) * proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The pill's window: borderless, above other windows and next to the pet. It never takes focus, so the app the user is
/// in keeps it.
@MainActor
final class VoicePillPanel {
    let panel: NSPanel
    private let host: NSHostingView<VoicePillView>
    private let petName: () -> String

    init(recorder: SpokenMessageRecorder, petName: @escaping () -> String, onEnd: @escaping () -> Void) {
        self.petName = petName
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        host = NSHostingView(rootView: VoicePillView(recorder: recorder, petName: petName(), onEnd: onEnd))
        panel.contentView = host
    }

    /// Shows the pill above the pet, or below it near the top of the screen.
    func present(near pet: CGRect) {
        host.rootView.petName = petName()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(pet) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: pet.midX - size.width / 2, y: pet.maxY + 6)
        if origin.y + size.height > screen.maxY { origin.y = pet.minY - size.height - 6 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}
