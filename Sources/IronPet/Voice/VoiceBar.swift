import IronPetCore
import IronPetKit
import SwiftUI

/// The content of the composer field while a voice note is recording or being transcribed: a live waveform across
/// the full width and the elapsed time. Cancel and stop sit outside the field, see `VoiceCancelButton` and `VoiceStopButton`.
struct VoiceBar: View {
    @ObservedObject var voice: VoiceController

    /// The idle field is `GlassCircleButtonStyle.size` tall including its 4 pt padding, so the bar fits inside it and the composer does not grow.
    private static let contentHeight = GlassCircleButtonStyle.size - 8

    private var transcribing: Bool { voice.phase == .transcribing }

    var body: some View {
        HStack(spacing: 10) {
            VoiceWaveform(levels: voice.levels, paused: transcribing)
                .frame(height: Self.contentHeight)
                .frame(maxWidth: .infinity)
                .opacity(transcribing ? 0.3 : 1)
                .animation(.easeOut(duration: 0.2), value: transcribing)
            if transcribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                ElapsedTime(since: voice.startedAt)
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: Self.contentHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(transcribing ? "Transcribing voice note" : "Recording voice note")
    }
}

/// Cancel, left of the field, the same size as the idle composer's attach button.
struct VoiceCancelButton: View {
    @ObservedObject var voice: VoiceController

    var body: some View {
        Button { voice.cancel() } label: { Image(systemName: SharedSymbols.deny) }
            .buttonStyle(GlassCircleButtonStyle())
            .help(voice.phase == .transcribing ? "Cancel transcription" : "Discard recording")
    }
}

/// Stop, right of the field, the same size as the idle composer's mic button. While transcribing it stays in the layout
/// but is invisible, so the field does not change width.
struct VoiceStopButton: View {
    @ObservedObject var voice: VoiceController

    private var transcribing: Bool { voice.phase == .transcribing }

    var body: some View {
        Button { voice.stop() } label: {
            Image(systemName: SharedSymbols.stop)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: GlassCircleButtonStyle.size, height: GlassCircleButtonStyle.size)
                .background(Color.red, in: Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Stop and transcribe")
        .opacity(transcribing ? 0 : 1)
        .allowsHitTesting(!transcribing)
        .accessibilityHidden(transcribing)
    }
}

/// `0:07 / 5:00`. The limit is shown because a note is cut off there instead of being split.
private struct ElapsedTime: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let seconds = Int(max(0, context.date.timeIntervalSince(since ?? context.date)))
            HStack(spacing: 3) {
                Text(Self.format(seconds)).foregroundStyle(.primary)
                Text("/ \(Self.format(Int(VoiceController.maxDuration)))").foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, design: .monospaced))
            .monospacedDigit()
            .help("A voice note is cut off at \(Int(VoiceController.maxDuration) / 60) minutes")
        }
    }

    static func format(_ seconds: Int) -> String { VoiceClock.format(seconds) }
}
