import SwiftUI
import IronPetKit

/// The microphone button of the composer. A tap starts a recording, a second tap ends it and the text lands in the composer.
struct MicButton: View {
    let voice: VoiceModel

    var body: some View {
        Button { Task { await voice.micTapped() } } label: {
            switch voice.state {
            case .idle:
                Image(systemName: voice.speaking ? "speaker.slash.fill" : SharedSymbols.microphoneActive).glassCircle()
            case .recording:
                Image(systemName: SharedSymbols.stop)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .frame(width: GlassCircleButtonStyle.size, height: GlassCircleButtonStyle.size)
                    .tintedCircle(.red)
            case .transcribing:
                ProgressView().frame(width: GlassCircleButtonStyle.size, height: GlassCircleButtonStyle.size).glassCircle()
            }
        }
        .buttonStyle(.plain)
        .disabled(voice.state == .transcribing)
        .accessibilityLabel(voice.state == .recording ? "Stop recording" : "Dictate")
        .accessibilityIdentifier("mic-button")
    }
}

/// Starts voice mode: the phone listens, ends the message itself after a pause and sends it to the primary chat. While it listens
/// the same button ends voice mode and sends nothing.
struct VoiceModeButton: View {
    let voice: VoiceModel

    var body: some View {
        Button { Task { await voice.voiceModeTapped() } } label: {
            if voice.voiceModeOn {
                Image(systemName: SharedSymbols.stop)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .frame(width: GlassCircleButtonStyle.size, height: GlassCircleButtonStyle.size)
                    .tintedCircle(.red)
            } else {
                Image(systemName: "waveform").glassCircle()
            }
        }
        .buttonStyle(.plain)
        .disabled(!voice.voiceModeOn && voice.state != .idle)
        .accessibilityLabel(voice.voiceModeOn ? "End voice mode" : "Voice mode")
        .accessibilityIdentifier("voice-mode-button")
    }
}

/// Takes the place of the composer while a voice note records: cancel, a live waveform, the elapsed time and stop.
struct VoiceRecordingBar: View {
    let voice: VoiceModel

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await voice.cancelRecording() } } label: {
                Image(systemName: SharedSymbols.deny).glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording").accessibilityIdentifier("voice-cancel")
            VoiceWaveform(levels: voice.levels)
                .frame(height: 34).frame(maxWidth: .infinity)
                .accessibilityIdentifier("voice-waveform")
            if voice.voiceModeOn {
                Text("Listening").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("voice-listening")
                VoiceModeButton(voice: voice)
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let seconds = Int(max(0, context.date.timeIntervalSince(voice.startedAt ?? context.date)))
                    Text(VoiceClock.format(seconds)).font(.system(size: 15, design: .monospaced)).monospacedDigit()
                        .accessibilityLabel("Recording time").accessibilityValue(VoiceClock.format(seconds))
                }
                .accessibilityIdentifier("voice-timer")
                MicButton(voice: voice)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-recording-bar")
    }
}

/// The two voice switches of this iPhone. They are stored on the phone: the Mac setting "Read replies aloud" is about the Mac's speaker.
struct VoiceSettingsSection: View {
    @Bindable var voice: VoiceModel

    var body: some View {
        Section {
            Toggle("Spoken replies", isOn: $voice.spokenReplies).accessibilityIdentifier("spoken-replies")
            Toggle("Send dictation at once", isOn: $voice.sendAtOnce).accessibilityIdentifier("send-dictation")
        } header: {
            Text("Voice on this iPhone")
        } footer: {
            Text("With spoken replies on, the Mac sends the audio of each reply to a message you sent from this iPhone, and the iPhone plays it. A tap on the microphone or typing stops it.")
        }
    }
}

/// Why the last recording failed or ended, above the composer. Without it a failed recording looks like a button that flips back.
struct VoiceNotice: View {
    let voice: VoiceModel

    var body: some View {
        if let message = voice.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Label(message, systemImage: "mic.slash").font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if voice.needsSettings {
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.footnote.weight(.semibold)).accessibilityIdentifier("voice-settings")
                }
                Button { voice.errorMessage = nil } label: { Image(systemName: "xmark").font(.footnote) }
                    .accessibilityLabel("Dismiss").accessibilityIdentifier("voice-error-dismiss")
            }
            .padding(.horizontal).padding(.vertical, 6)
            .background(.thinMaterial).accessibilityIdentifier("voice-error")
        }
    }
}
