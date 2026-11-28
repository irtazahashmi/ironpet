import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import SwiftUI
import UniformTypeIdentifiers

/// The Transcripts section: past meetings newest first, and the summary or transcript of the one selected.
struct TranscriptsView: View {
    @ObservedObject var meetings: MeetingsAPI
    /// A meeting to select, set by the Today page. Cleared once selected.
    let focus: Binding<String?>

    init(meetings: MeetingsAPI, focus: Binding<String?> = .constant(nil)) {
        self.meetings = meetings
        self.focus = focus
    }

    /// The meeting open in full. Nil shows the list.
    @State private var selection: String?
    @State private var search = ""
    @State private var page: Page = .summary
    @State private var text: String?
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var suggestions = MeetingSuggestions()
    @State private var titleDraft = ""
    @State private var speakerDrafts: [String: String] = [:]

    enum Page: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    var body: some View {
        ListScreen(title: IronPetSection.transcripts.title, search: $search, detailOpen: selection != nil, trailing: {
            HStack(spacing: 8) {
                if let label = meetings.regenerationProgress?.label ?? meetings.importStage {
                    ProgressView().controlSize(.small)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                Button { chooseAudio() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .controlSize(.small)
                    .disabled(meetings.isImporting || meetings.regenerationID != nil)
                    .help("Turn an m4a, mp3 or wav file into a meeting with a transcript, speakers and summary. You can also drop the file on this list.")
            }
        }) {
            VStack(spacing: 0) {
                if let message = meetings.importError {
                    Text(message).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if meetings.meetings.isEmpty {
                    EmptyState(symbol: SharedSymbols.meetings, title: "No meetings yet",
                               detail: "Start one from \(SettingsAPI.live.config.pet.name)'s right-click menu, or press Import or drop an m4a, mp3 or wav file here. Its transcript and summary show up here.")
                } else if selected != nil {
                    detail
                } else {
                    list
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { _ = meetings.startImport(of: [url]) }
                }
            }
            return !providers.isEmpty
        }
        .onAppear {
            meetings.reload()
            selectFocus()
            load()
            loadSuggestions()
        }
        .onChange(of: focus.wrappedValue) { selectFocus() }
        .onChange(of: selection) { load(); loadSuggestions() }
        .onChange(of: page) { load() }
        // A run changed files on disk: the list previews and the open text may be new.
        .onChange(of: meetings.regenerationsCompleted) {
            meetings.reload()
            load()
            loadSuggestions()
        }
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = meetings.importExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Pick an audio recording to import as a meeting"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        _ = meetings.startImport(of: panel.urls)
    }

    private func selectFocus() {
        guard let id = focus.wrappedValue else { return }
        focus.wrappedValue = nil
        guard meetings.meetings.contains(where: { $0.id == id }) else { return }
        page = .summary
        selection = id
    }

    private var selected: MeetingRecord? { meetings.meetings.first { $0.id == selection } }

    /// What the Transcripts search looks at: the date as the row shows it, and the preview.
    static func title(_ meeting: MeetingRecord) -> String {
        let date = meeting.date.formatted(date: .abbreviated, time: .shortened)
        return meeting.title.map { "\($0), \(date)" } ?? date
    }

    /// The row's heading: the title when there is one, otherwise the date.
    static func heading(_ meeting: MeetingRecord) -> String {
        meeting.title ?? meeting.date.formatted(date: .abbreviated, time: .shortened)
    }

    static func filter(_ meetings: [MeetingRecord], query: String) -> [MeetingRecord] {
        ListSearch.filter(meetings, query: query, title: title, description: \.preview)
    }

    @ViewBuilder private var list: some View {
        let shown = Self.filter(meetings.meetings, query: search)
        if shown.isEmpty {
            NoMatches()
        } else {
            ListScroll {
                ForEach(shown) { meeting in
                    let recording = meeting.folder == meetings.activeFolder
                    ListRow(title: Self.heading(meeting),
                            description: meeting.preview.isEmpty ? (recording ? "Recording…" : "No transcript") : meeting.preview,
                            emphasized: true, onOpen: { page = .summary; selection = meeting.id },
                            leading: { ListRowIcon(symbol: recording ? "record.circle" : SharedSymbols.meetings, color: recording ? .red : .secondary) },
                            extra: {
                                if meetings.regenerationID == meeting.id, let progress = meetings.regenerationProgress {
                                    HStack(spacing: 5) {
                                        ProgressView().controlSize(.mini)
                                        Text(progress.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            },
                            trailing: { _ in EmptyView() })
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let meeting = selected {
            VStack(alignment: .leading, spacing: 0) {
                ListBackBar(section: "Transcripts", onBack: { selection = nil })
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(Self.heading(meeting)).font(.system(size: 20, weight: .bold)).textSelection(.enabled)
                            if meeting.title != nil {
                                Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let ref = meetings.ref(meeting) { RecordIDLine(ref: ref) }
                            // At the narrowest window the Ask label would be cut, so it falls back to its icon.
                            ViewThatFits(in: .horizontal) {
                                toolbar(meeting, askLabel: true)
                                toolbar(meeting, askLabel: false)
                            }
                            .controlSize(.small)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardMaterial()
                        if meeting.isRoom, !suggestions.isEmpty || meeting.title != nil { suggestionsCard(meeting) }
                        TranscriptTextCard(title: page.rawValue, text: text)
                    }
                    .padding(.horizontal, ListScreenMetrics.gutter + 4)
                    .padding(.vertical, 14)
                    .listColumn()
                }
                if let message = error ?? meetings.regenerationErrors[meeting.id] {
                    Text(message).font(.caption).foregroundStyle(.red).padding(8)
                }
            }
            .onExitCommand { selection = nil }
            .confirmationDialog("Move this meeting to the Trash?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { delete(meeting) }
            } message: {
                Text("Its audio chunks, transcript and summary go to the Trash.")
            }
        }
    }

    /// The title and speaker names the summary agent proposed. Each is a text field the user can correct, and Use stores it.
    private func suggestionsCard(_ meeting: MeetingRecord) -> some View {
        CardSection(title: "Suggestions") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Title", text: $titleDraft).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Meeting title")
                    Button(meeting.title == nil ? "Use" : "Save") { acceptTitle(meeting) }
                        .disabled(titleDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(suggestions.speakers.keys.sorted(), id: \.self) { label in
                    HStack {
                        Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        TextField("Name", text: Binding(get: { speakerDrafts[label] ?? suggestions.speakers[label] ?? "" },
                                                        set: { speakerDrafts[label] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Name for \(label)")
                        Button("Use") { acceptSpeaker(meeting, label) }
                            .disabled((speakerDrafts[label] ?? suggestions.speakers[label] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack {
                    Spacer()
                    Button("Dismiss") { dismissSuggestions(meeting) }.controlSize(.small)
                }
            }
            .padding(14)
        }
    }

    private func loadSuggestions() {
        guard let meeting = selected else { suggestions = MeetingSuggestions(); titleDraft = ""; speakerDrafts = [:]; return }
        suggestions = (try? meetings.suggestions(meeting.id)) ?? MeetingSuggestions()
        titleDraft = meeting.title ?? suggestions.title ?? ""
        speakerDrafts = [:]
    }

    private func acceptTitle(_ meeting: MeetingRecord) {
        run { try meetings.acceptTitle(meeting.id, title: titleDraft) }
    }

    private func acceptSpeaker(_ meeting: MeetingRecord, _ label: String) {
        run { try meetings.acceptSpeakerSuggestion(meeting.id, label: label, name: speakerDrafts[label] ?? suggestions.speakers[label] ?? "") }
    }

    private func dismissSuggestions(_ meeting: MeetingRecord) {
        run { try meetings.dismissSuggestions(meeting.id) }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
        meetings.reload()
        loadSuggestions()
        load()
    }

    private func toolbar(_ meeting: MeetingRecord, askLabel: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button { try? meetings.ask(meeting.id) } label: {
                if askLabel {
                    Label("Ask \(SettingsAPI.live.config.pet.name)", systemImage: "sparkles")
                } else {
                    Label("Ask \(SettingsAPI.live.config.pet.name)", systemImage: "sparkles").labelStyle(.iconOnly)
                }
            }
            .disabled(meeting.chatFiles.isEmpty)
            .help("Open the chat with this meeting's transcript and summary attached")
            regenerateMenu(meeting)
            IconButton(symbol: "folder", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
            }
            IconButton(symbol: "trash", help: "Move to Trash") { confirmDelete = true }
                .disabled(meeting.folder == meetings.activeFolder || meetings.regenerationID == meeting.id)
        }
    }

    /// Click for a new transcript and summary, or pick "Summary only" to keep the transcript, for example after naming a speaker.
    private func regenerateMenu(_ meeting: MeetingRecord) -> some View {
        let reason = meetings.regenerationBlocked(meeting.id)
        return Menu {
            Button("Transcript and summary") { regenerate(meeting, .full) }
            Button("Summary only") { regenerate(meeting, .summaryOnly) }
                .disabled(!meeting.hasTranscript)
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
        } primaryAction: {
            regenerate(meeting, .full)
        }
        .fixedSize()
        .accessibilityLabel("Regenerate transcript and summary")
        .disabled(reason != nil)
        .help(reason ?? "Transcribe the saved audio again and write a new summary, with today's model, speaker names and summary agent. The old files are kept as .prev.md")
    }

    private func regenerate(_ meeting: MeetingRecord, _ mode: MeetingRegeneration) {
        error = nil
        Task { try? await meetings.regenerate(RegenerateMeetingRequest(id: meeting.id, mode: mode)) }
    }

    private func load() {
        guard let meeting = selected else { text = nil; return }
        let id = meeting.id, wanted = page
        text = nil
        Task {
            let loaded = (try? await meetings.text(MeetingTextRequest(id: id, kind: wanted == .summary ? .summary : .transcript))) ?? nil
            // A slow read for a meeting the user already left must not replace the newer one.
            guard selection == id, page == wanted else { return }
            text = loaded
        }
    }

    private func delete(_ meeting: MeetingRecord) {
        do {
            try meetings.delete(meeting.id)
            error = nil
            selection = nil
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}

/// The summary or the transcript of a meeting, as one card. It says so when there is nothing to show.
struct TranscriptTextCard: View {
    let title: String
    let text: String?

    var body: some View {
        CardSection(title: title) {
            Group {
                if let text, !text.isEmpty {
                    MarkdownView(text: text, size: 13)
                } else {
                    Text("No \(title.lowercased()) for this meeting.").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
