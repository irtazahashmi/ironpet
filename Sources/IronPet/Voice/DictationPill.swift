import IronPetCore
import IronPetKit
import SwiftUI

/// The recording bar for dictation in other apps: a dark capsule with a recording dot, a live level meter made of
/// dots, and a round close button. The dot and the meter use the app's accent colour, the one the chat uses.
/// Stopping is the dictation shortcut (or Enter); closing discards the recording.
struct DictationPill: View {
    @ObservedObject var voice: VoiceController
    /// The app's accent. Previews pass others.
    var accent: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transcribing: Bool { voice.phase == .transcribing }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .opacity(transcribing ? 0.4 : 1)
                .accessibilityHidden(true)
            DotMeter(levels: voice.levels, accent: accent, paused: transcribing, reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity)
                .frame(height: 14)
            Button { voice.cancel() } label: {
                Image(systemName: SharedSymbols.deny)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(transcribing ? "Cancel transcription" : "Discard recording")
            .accessibilityLabel(transcribing ? "Cancel transcription" : "Discard recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(width: DictationPill.size.width, height: DictationPill.size.height)
        .background(Color(white: 0.14, opacity: 0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(transcribing ? "Transcribing dictation" : "Recording dictation")
    }

    static let size = CGSize(width: 190, height: 36)
}

/// A row of dots. Each dot swells with the level it shows, and the newest level is on the right.
private struct DotMeter: View {
    let levels: LevelBuffer
    let accent: Color
    let paused: Bool
    let reduceMotion: Bool

    private static let count = 11
    private static let pitch: CGFloat = 8

    var body: some View {
        if reduceMotion || paused {
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in dots(frame: timeline.date) }
        } else {
            TimelineView(.animation) { timeline in dots(frame: timeline.date) }
        }
    }

    private func dots(frame: Date) -> some View {
        Canvas { context, size in
            _ = frame
            let (bars, _) = levels.recent(Self.count)
            let padded = Array(repeating: Float(0), count: max(0, Self.count - bars.count)) + bars
            let width = CGFloat(Self.count - 1) * Self.pitch
            let startX = (size.width - width) / 2
            for (index, level) in padded.suffix(Self.count).enumerated() {
                let amount = paused ? 0 : CGFloat(min(1, max(0, level)))
                let diameter = 3 + 3 * amount
                let rect = CGRect(x: startX + CGFloat(index) * Self.pitch - diameter / 2, y: size.height / 2 - diameter / 2,
                                  width: diameter, height: diameter)
                context.fill(Path(ellipseIn: rect), with: .color(accent.opacity(0.45 + 0.55 * Double(amount))))
            }
        }
        .accessibilityHidden(true)
    }
}
