import IronPetCore
import IronPetKit
import SwiftUI

/// Replaces the whole composer while a voice note is recording or being transcribed: cancel, a live waveform across
/// the full width, the elapsed time, and stop. Nothing else from the composer stays visible.
struct VoiceBar: View {
    @ObservedObject var voice: VoiceController

    private var transcribing: Bool { voice.phase == .transcribing }

    var body: some View {
        HStack(spacing: 10) {
            circleButton(SharedSymbols.deny, help: transcribing ? "Cancel transcription" : "Discard recording") { voice.cancel() }
            VoiceWaveform(levels: voice.levels, paused: transcribing)
                .frame(height: 34)
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
                Button { voice.stop() } label: {
                    Image(systemName: SharedSymbols.stop)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop and transcribe")
            }
        }
        .frame(minHeight: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(transcribing ? "Transcribing voice note" : "Recording voice note")
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
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
