import IronPetKit
import SwiftUI
import UniformTypeIdentifiers

/// Meetings: locked until Face ID or the passcode says yes. The views are `privacySensitive`, so the app switcher shows them blurred.
struct MeetingsView: View {
    let model: MeetingsModel
    let uploads: MeetingUploadsModel
    @State private var picking = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var deleting: RemoteMeeting?
    /// The system prompt opens with the screen once. After Lock, or a refusal, the person taps Unlock.
    @State private var prompted = false

    var body: some View {
        Group {
            if model.gate.isUnlocked { unlocked } else { locked }
        }
        .navigationTitle("Meetings")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .fullPageLoadError(model)
        .privacySensitive()
        .onChange(of: scenePhase) { _, phase in
            model.gate.scenePhaseChanged(phase)
            // Back after five minutes away: ask again at once, as the lock screen would.
            if phase == .active, !model.gate.isUnlocked, prompted { Task { await model.unlock() } }
        }
        // Leaving the screen does not lock it: the five minutes in the background do. Opening it asks first.
        .task { model.start() }
    }

    /// What the picker offers. The Mac refuses anything that is not m4a, mp3 or wav in the same words, so a file picked by another route (all files) is still checked.
    private static let audioTypes: [UTType] = [.mpeg4Audio, .mp3, .wav, .audio]

    private var locked: some View {
        ContentUnavailableView {
            Label("Meetings are locked", systemImage: "lock.fill")
        } description: {
            Text(model.gate.refused ? "Face ID or the passcode did not match." : "Meeting text is private. Unlock to read it.")
        } actions: {
            Button("Unlock") { Task { await model.unlock() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("unlock-meetings")
        }
        .task {
            guard !prompted else { return }
            prompted = true
            await model.unlock()
        }
    }

    private var unlocked: some View {
        List {
            Group {
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle").accessibilityIdentifier("meetings-notice")
                }
                if model.state.isRecording {
                    Section {
                        Label("Recording\(model.state.appName.isEmpty ? "" : " · \(model.state.appName)")", systemImage: "record.circle").foregroundStyle(.red)
                            .accessibilityIdentifier("recording-state")
                        Button("Stop recording", role: .destructive) { Task { await model.stopRecording() } }.accessibilityIdentifier("stop-recording")
                    } footer: {
                        Text("Recording can only be started on the Mac.")
                    }
                } else if model.state.phase == "summarizing" || model.state.phase == "finishing" {
                    Label("Summarizing…", systemImage: "hourglass").accessibilityIdentifier("summarizing-state")
                }
                UploadsSection(uploads: uploads)
                ForEach(model.meetings) { meeting in
                    NavigationLink {
                        MeetingDetailView(model: model, meeting: meeting)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = meeting.title, !title.isEmpty {
                                Text(title).font(.headline).accessibilityIdentifier("meeting-title-\(meeting.id)")
                                Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            }
                            if !meeting.preview.isEmpty { Text(meeting.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                            if meeting.active { Text("In progress").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    .accessibilityIdentifier("meeting-\(meeting.id)")
                    .swipeActions { Button("Delete", role: .destructive) { deleting = meeting } }
                }
                if model.showsEmptyState {
                    ContentUnavailableView("No meetings", systemImage: SharedSymbols.meetings, description: Text("Meetings recorded on the Mac show up here."))
                }
        
            }.listRowBackground(SharedTheme.card)
        }
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Lock") { model.gate.lock() }.accessibilityIdentifier("lock-meetings") }
            ToolbarItem(placement: .topBarLeading) { Button("Upload", systemImage: "square.and.arrow.up") { picking = true }.accessibilityIdentifier("upload-meeting") }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.audioTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { uploads.add(urls) }
        }
        .confirmationDialog("Move this meeting to the Trash on the Mac?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let target = deleting { Task { await model.delete(target) } }
                deleting = nil
            }
        }
    }
}

struct MeetingDetailView: View {
    let model: MeetingsModel
    let meeting: RemoteMeeting
    @State private var kind = "summary"
    @State private var text: String?
    @State private var loading = true
    @State private var confirmingRebuild = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let ref = meeting.ref { RecordIDLine(ref: ref) }
                Picker("Text", selection: $kind) {
                    Text("Summary").tag("summary")
                    Text("Transcript").tag("transcript")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("meeting-kind")
                if let text {
                    Text(text).textSelection(.enabled).accessibilityIdentifier("meeting-text")
                } else if loading {
                    ProgressView()
                } else if model.network.failingSince != nil {
                    LoadErrorView { await load() }
                } else {
                    Text("This meeting has no \(kind) yet.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .privacySensitive()
        .navigationTitle(meeting.date.formatted(date: .abbreviated, time: .shortened))
        .themedScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Ask Ghost") { Task { await model.ask(meeting) } }.accessibilityIdentifier("ask-meeting")
                    Button("Rebuild summary") { Task { await model.regenerate(meeting, summaryOnly: true) } }.accessibilityIdentifier("rebuild-summary")
                    if meeting.hasAudio { Button("Transcribe again…") { confirmingRebuild = true }.accessibilityIdentifier("rebuild-full") }
                } label: { Image(systemName: SharedSymbols.more) }
                    .accessibilityIdentifier("meeting-menu")
            }
        }
        .confirmationDialog("Transcribe the audio on the Mac again?", isPresented: $confirmingRebuild, titleVisibility: .visible) {
            Button("Transcribe again") { Task { await model.regenerate(meeting, summaryOnly: false) } }
        } message: {
            Text("The audio goes to the voice server again. The old files stay on the Mac as .prev.md.")
        }
        .task(id: kind) { await load() }
        // Locking drops the text from the model, so the screen drops its copy too.
        .onChange(of: model.gate.isUnlocked) { _, unlocked in if !unlocked { text = nil } }
    }

    private func load() async {
        loading = true
        text = await model.text(meeting.id, kind)
        loading = false
    }
}

/// The files that wait on the phone for the Mac, with the Mac's refusal for a file it would not take.
private struct UploadsSection: View {
    let uploads: MeetingUploadsModel

    var body: some View {
        if let message = uploads.message {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("upload-message")
        }
        ForEach(uploads.waiting) { upload in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(upload.fileName).font(.headline).lineLimit(1)
                    Text(uploads.sending ? "Sending to your Mac. The file stays here until the Mac has all of it." : "Waiting for your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("upload-\(upload.id)")
        }
        ForEach(uploads.failed) { upload in
            VStack(alignment: .leading, spacing: 4) {
                Text(upload.fileName).font(.headline).lineLimit(1)
                Text(upload.failure ?? "").font(.caption).foregroundStyle(.red)
                Button("Dismiss") { uploads.dismiss(upload) }.font(.caption)
            }
            .accessibilityIdentifier("upload-failed-\(upload.id)")
        }
    }
}
