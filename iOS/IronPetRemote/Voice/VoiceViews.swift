import SwiftUI

/// The microphone button of the composer. A tap starts a recording, a second tap ends it and the text lands in the composer.
struct MicButton: View {
    let voice: VoiceModel

    var body: some View {
        Button { Task { await voice.micTapped() } } label: {
            switch voice.state {
            case .idle:
                Image(systemName: voice.speaking ? "speaker.slash.fill" : "mic.fill").glassCircle()
            case .recording:
                Image(systemName: "stop.fill")
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
