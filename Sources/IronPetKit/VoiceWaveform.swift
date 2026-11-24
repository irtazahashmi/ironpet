import Foundation
#if canImport(SwiftUI)
import SwiftUI

/// Mirrored bars scrolling right to left, drawn from a `LevelBuffer` on the display's own timeline. The Mac voice bar and the
/// iPhone recording bar share it. With Reduce Motion on it redraws a few times a second and steps instead of scrolling.
public struct VoiceWaveform: View {
    let levels: LevelBuffer
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 2.5

    public init(levels: LevelBuffer, paused: Bool = false) {
        self.levels = levels
        self.paused = paused
    }

    public var body: some View {
        // Reduce Motion stops the `.animation` schedule from ticking, so it gets a plain periodic one.
        Group {
            if reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                    bars(frame: timeline.date)
                }
            } else {
                TimelineView(.animation(paused: paused)) { timeline in
                    bars(frame: timeline.date)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// `levels` is a reference type, so the Canvas only redraws if its closure captures something that
    /// changes every frame. The timeline date does that.
    private func bars(frame: Date) -> some View {
        Canvas { context, size in
            _ = frame
            let pitch = Self.barWidth + Self.gap
            let count = Int(size.width / pitch) + 2
            let (bars, phase) = levels.recent(count)
            let shift = reduceMotion ? 0 : CGFloat(phase) * pitch
            for (index, level) in bars.enumerated() {
                let x = size.width - CGFloat(bars.count - index) * pitch - shift + pitch
                guard x > -pitch, x < size.width else { continue }
                let height = max(Self.barWidth, CGFloat(level) * size.height)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
                // Older bars fade out toward the left edge.
                let fade = min(1, max(0.15, x / (size.width * 0.35)))
                context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                             with: .color(.accentColor.opacity(fade)))
            }
        }
    }
}
#endif

/// The `m:ss` clock of a recording.
public enum VoiceClock {
    public static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
