import AppKit
import IronPetCore
import SwiftUI

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

    enum Page: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    var body: some View {
        ListScreen(title: IronPetSection.transcripts.title, search: $search, detailOpen: selection != nil, trailing: {
            if let progress = meetings.regenerationProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }) {
            VStack(spacing: 0) {
                if meetings.meetings.isEmpty {
                    EmptyState(symbol: "waveform", title: "No meetings yet",
                               detail: "Start one from \(SettingsAPI.live.config.pet.name)'s right-click menu; its transcript and summary show up here.")
                } else if selected != nil {
                    detail
                } else {
                    list
                }
            }
        }
        .onAppear {
            meetings.reload()
            selectFocus()
            load()
        }
        .onChange(of: focus.wrappedValue) { selectFocus() }
        .onChange(of: selection) { load() }
        .onChange(of: page) { load() }
        // A run changed files on disk: the list previews and the open text may be new.
        .onChange(of: meetings.regenerationsCompleted) {
            meetings.reload()
            load()
        }
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
    static func title(_ meeting: MeetingRecord) -> String { meeting.date.formatted(date: .abbreviated, time: .shortened) }

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
                    ListRow(title: Self.title(meeting),
                            description: meeting.preview.isEmpty ? (recording ? "Recording…" : "No transcript") : meeting.preview,
                            emphasized: true, onOpen: { page = .summary; selection = meeting.id },
                            leading: { ListRowIcon(symbol: recording ? "record.circle" : "waveform", color: recording ? .red : .secondary) },
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
                // At the narrowest window the Ask label would be cut, so it falls back to its icon.
                ViewThatFits(in: .horizontal) {
                    toolbar(meeting, askLabel: true)
                    toolbar(meeting, askLabel: false)
                }
                .controlSize(.small)
                .padding(.horizontal, ListScreenMetrics.gutter)
                .padding(.vertical, 8)
                .listColumn()
                Divider()
                ScrollView {
                    Group {
                        if let text, !text.isEmpty {
                            MarkdownView(text: text, size: 13)
                        } else {
                            Text(page == .summary ? "No summary for this meeting." : "No transcript for this meeting.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
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
