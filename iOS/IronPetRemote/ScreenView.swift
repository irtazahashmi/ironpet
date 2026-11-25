import IronPetKit
import SwiftUI

/// Covers the content whenever the app is not active, so the snapshot iOS takes for the app switcher shows a plain screen. The system
/// takes it as the scene goes inactive, before the app is in the background.
struct ScreenPrivacyCover: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    static func isCovered(_ phase: ScenePhase) -> Bool { phase != .active }

    func body(content: Content) -> some View {
        content
            .overlay {
                if Self.isCovered(scenePhase) {
                    ZStack {
                        Rectangle().fill(.background)
                        Label("Screen text is hidden", systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                    .ignoresSafeArea()
                    .accessibilityIdentifier("screen-cover")
                }
            }
    }
}

extension View {
    func screenPrivacy() -> some View { privacySensitive().modifier(ScreenPrivacyCover()) }
}

/// Screen capture on the phone: locked until Face ID or the passcode says yes, and again after five minutes in the background.
struct ScreenView: View {
    let model: ScreenModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var prompted = false

    var body: some View {
        Group {
            if model.gate.isUnlocked { unlocked } else { locked }
        }
        .navigationTitle("Screen")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .fullPageLoadError(model)
        .screenPrivacy()
        .onChange(of: scenePhase) { _, phase in
            model.gate.scenePhaseChanged(phase)
            if phase == .active, !model.gate.isUnlocked, prompted { Task { await model.unlock() } }
        }
        .task { model.start() }
    }

    private var locked: some View {
        ContentUnavailableView {
            Label("Screen text is locked", systemImage: "lock.fill")
        } description: {
            Text(model.gate.refused ? "Face ID or the passcode did not match." : "Text from your Mac's screen is private. Unlock to read it.")
        } actions: {
            Button("Unlock") { Task { await model.unlock() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("unlock-screen")
        }
        .task {
            guard !prompted else { return }
            prompted = true
            await model.unlock()
        }
    }

    @ViewBuilder private var unlocked: some View {
        if model.forbidden {
            ContentUnavailableView {
                Label("Screen text is off for this phone", systemImage: SharedSymbols.approval)
            } description: {
                Text("On the Mac, open Settings, then Devices, and turn on Screen text for this phone.")
            } actions: {
                Button("Check again") { Task { await model.refresh() } }.accessibilityIdentifier("screen-check-again")
            }
            .accessibilityIdentifier("screen-forbidden")
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Group {
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle").accessibilityIdentifier("screen-notice")
                }
                statusSection
                if let searched = model.searched { searchResults(searched) } else { changes }
        
            }.listRowBackground(SharedTheme.card)
        }
        .refreshable { await model.refresh() }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search screen text")
        .onSubmit(of: .search) { Task { await model.search(query) } }
        .onChange(of: query) { _, text in if text.isEmpty { model.clearSearch() } }
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Lock") { model.gate.lock() }.accessibilityIdentifier("lock-screen") } }
    }

    @ViewBuilder private var statusSection: some View {
        if let status = model.status {
            Section {
                if status.paused {
                    Label("Paused" + (status.pausedUntil.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? ""), systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange).accessibilityIdentifier("screen-status")
                } else if status.running {
                    Label("Capturing", systemImage: "record.circle").foregroundStyle(.green).accessibilityIdentifier("screen-status")
                } else {
                    Label("Capture is off", systemImage: "circle.slash").foregroundStyle(.secondary).accessibilityIdentifier("screen-status")
                }
                LabeledContent("Captures stored", value: "\(status.captureCount)")
                if let last = status.lastCapture { LabeledContent("Last capture", value: last.formatted(date: .omitted, time: .shortened)) }
                if status.running, !status.paused {
                    Button("Pause for 15 minutes") { Task { await model.pause(minutes: 15) } }.accessibilityIdentifier("pause-15")
                    Button("Pause for 1 hour") { Task { await model.pause(minutes: 60) } }.accessibilityIdentifier("pause-60")
                    Button("Pause until tomorrow") { Task { await model.pause(minutes: nil) } }.accessibilityIdentifier("pause-tomorrow")
                }
            } footer: {
                Text("Resuming capture happens on the Mac.")
            }
        }
    }

    @ViewBuilder private var changes: some View {
        Section {
            Picker("Range", selection: Binding(get: { model.range }, set: { next in Task { await model.setRange(next) } })) {
                ForEach(ScreenRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("screen-range")
        }
        ForEach(model.windows) { window in
            Section {
                ForEach(window.changes, id: \.self) { line in
                    if let id = RemoteScreenWindow.captureID(in: line) {
                        NavigationLink { ScreenCaptureView(model: model, id: id) } label: { ChangeLine(line: line) }
                            .accessibilityIdentifier("screen-change-c\(id)")
                    } else {
                        ChangeLine(line: line)
                    }
                }
                if let more = window.more, more > 0 { Text("\(more) older").font(.caption).foregroundStyle(.secondary) }
            } header: {
                VStack(alignment: .leading) {
                    Text("\(window.app) · \(window.window)").textCase(nil).accessibilityIdentifier("screen-window-\(window.app)")
                    if let container = window.container { Text("in \(container)").font(.caption2).textCase(nil) }
                }
            }
        }
        if model.showsEmptyState {
            ContentUnavailableView("Nothing captured", systemImage: "rectangle.dashed", description: Text("No changes in this range."))
        }
    }

    @ViewBuilder private func searchResults(_ text: String) -> some View {
        Section("Results for \"\(text)\"") {
            ForEach(model.hits) { hit in
                NavigationLink { ScreenCaptureView(model: model, id: hit.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(hit.app) · \(hit.window)").font(.subheadline.weight(.semibold))
                        Text(hit.snippet).font(.callout).lineLimit(3)
                        Text(hit.time.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("screen-hit-\(hit.id)")
            }
            if model.hits.isEmpty { Text("No captures match.").foregroundStyle(.secondary).accessibilityIdentifier("screen-no-hits") }
        }
    }
}

private struct ChangeLine: View {
    let line: String

    /// `time kind | label | date | c12 #ref`. The last field holds the capture id, which the row's link already carries.
    private var fields: [String] {
        var parts = line.components(separatedBy: " | ")
        if parts.count > 1, RemoteScreenWindow.captureID(in: parts[parts.count - 1]) != nil { parts.removeLast() }
        return parts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let first = fields.first { Text(first).font(.caption).foregroundStyle(.secondary) }
            Text(fields.dropFirst().joined(separator: " · ")).font(.callout)
        }
    }
}

/// One capture: the outline of its window, or its text when it was read from pixels.
struct ScreenCaptureView: View {
    let model: ScreenModel
    let id: Int
    @State private var capture: RemoteScreenCapture?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let capture {
                    Text("\(capture.app) · \(capture.window)").font(.headline)
                    Text(capture.time.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Text(capture.outline ?? capture.text ?? "").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("screen-capture-text")
                } else if loading {
                    ProgressView()
                } else if model.network.failingSince != nil {
                    LoadErrorView { await load() }
                } else {
                    Text("This capture is gone or the screen is locked.").foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Capture")
        .themedScreen()
        .navigationBarTitleDisplayMode(.inline)
        .screenPrivacy()
        // Runs again when the screen unlocks, so a capture opened before a lock loads again instead of staying empty.
        .task(id: model.gate.isUnlocked) { await load() }
        // Locking drops the text from the model, so the screen drops its copy too.
        .onChange(of: model.gate.isUnlocked) { _, unlocked in if !unlocked { capture = nil } }
    }

    private func load() async {
        loading = true
        capture = await model.capture(id)
        loading = false
    }
}
