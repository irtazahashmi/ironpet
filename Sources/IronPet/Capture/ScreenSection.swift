import AppKit
import IronPetCore
import SwiftUI

/// The text of the Screen section, kept apart from the view so tests can check it.
enum ScreenSectionText {
    static func summary(captures: Int, lastCapture: Date?, now: Date = Date()) -> String {
        guard captures > 0 else { return "Nothing captured yet." }
        let count = "\(captures) \(captures == 1 ? "capture" : "captures") stored"
        guard let lastCapture else { return count }
        return count + ", the last one \(lastCapture.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }

    /// The first `lines` lines of a capture, with `…` when there are more.
    static func preview(_ text: String, lines: Int = 2) -> String {
        let all = text.split(whereSeparator: \.isNewline).map(String.init)
        let head = all.prefix(lines).joined(separator: "\n")
        return all.count > lines ? head + " …" : head
    }

    /// The window title, or the address when a page has no title.
    static func windowLabel(_ capture: StoredCapture) -> String { capture.window.isEmpty ? (capture.url ?? "Untitled window") : capture.window }
}

/// The Screen section: the most recent captures and a search over everything stored. It reads the local database only. Nothing here
/// goes to a model, to MCP or to a log.
struct ScreenSection: View {
    @ObservedObject var model: CaptureStatusModel
    @ObservedObject private var config = SettingsAPI.live
    /// The stored captures. Nil before the app has started.
    var screen: ScreenAPI?
    var onOpenSettings: () -> Void = {}
    var onAppear: () -> Void = {}

    @State private var recent: [StoredCapture] = []
    @State private var hits: [CaptureHit] = []
    @State private var search = ""
    @State private var nav = ListNavigation<Int64>()
    @State private var openText: [Int64: String] = [:]
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        // The search field in the title row asks the capture database, which matches rows that have all of the words.
        ListScreen(title: IronPetSection.screen.title, search: $search, detailOpen: nav.opened != nil) {
            if let id = nav.opened {
                detail(id)
            } else {
                list
            }
        }
        .onAppear { onAppear(); refresh() }
        .onReceive(timer) { _ in if query.isEmpty { refresh() } }
        .onChange(of: model.captureCount) { _ in refresh() }
        .onChange(of: search) { _ in refresh() }
    }

    private var list: some View {
        ListScroll {
            VStack(alignment: .leading, spacing: 4) {
                Text(ScreenSectionText.summary(captures: model.captureCount, lastCapture: model.lastCapture))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !config.config.screenCapture.enabled {
                    HStack {
                        Text("Screen capture is off").font(.caption).foregroundStyle(.secondary)
                        Button("Open Settings", action: onOpenSettings).controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 2)
            if query.isEmpty {
                if recent.isEmpty { Text("Captures appear here once screen capture has read a window.").font(.caption).foregroundStyle(.secondary) }
                ForEach(recent) { capture in
                    row(id: capture.id, at: capture.at, app: capture.appName, window: ScreenSectionText.windowLabel(capture),
                        text: ScreenSectionText.preview(capture.text, lines: 1))
                }
            } else {
                if hits.isEmpty { NoMatches() }
                ForEach(hits) { hit in
                    row(id: hit.id, at: hit.at, app: hit.appName, window: hit.window.isEmpty ? (hit.url ?? "Untitled window") : hit.window, text: hit.snippet)
                }
            }
            Text("Text is stored on this Mac with secrets redacted, and is deleted after \(config.config.screenCapture.retentionDays) days.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private func row(id: Int64, at: Date, app: String, window: String, text: String) -> some View {
        ListRow(title: "\(app): \(window)", description: text.replacingOccurrences(of: "\n", with: " "), emphasized: true,
                onOpen: { nav.open(id); loadText(id) },
                leading: { ListRowIcon(symbol: "macwindow") },
                extra: { EmptyView() },
                trailing: { _ in
                    Text(at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                })
    }

    @ViewBuilder private func detail(_ id: Int64) -> some View {
        let capture = recent.first { $0.id == id }
        let hit = hits.first { $0.id == id }
        let title = capture.map { "\($0.appName): \(ScreenSectionText.windowLabel($0))" }
            ?? hit.map { "\($0.appName): \($0.window.isEmpty ? ($0.url ?? "Untitled window") : $0.window)" } ?? "Capture"
        let at = capture?.at ?? hit?.at
        ScreenCaptureDetail(title: title, app: capture?.appName ?? hit?.appName, at: at, text: openText[id] ?? capture?.text ?? hit?.snippet ?? "",
                            ref: screen?.captureRef(id), onBack: { nav.close() })
            .onExitCommand { nav.close() }
    }

    /// Reads the database off the main thread. An answer for a search the user has since changed is dropped.
    private func refresh() {
        guard let screen else { return }
        let asked = query
        Task {
            let found = asked.isEmpty ? await screen.recent(limit: 50) : []
            let matched = asked.isEmpty ? [] : ((try? await screen.search(ScreenSearchRequest(query: asked, limit: 50))) ?? [])
            guard asked == query else { return }
            if asked.isEmpty { recent = found } else { hits = matched }
        }
    }

    private func loadText(_ id: Int64) {
        guard let screen else { return }
        Task { openText[id] = await screen.captureText(id) }
    }
}

/// One capture in full, as cards: the app, window and time, then the stored text.
struct ScreenCaptureDetail: View {
    let title: String
    let app: String?
    let at: Date?
    let text: String
    /// The capture's public `screen_` id, shown under the time.
    var ref: String? = nil
    let onBack: () -> Void

    var body: some View {
        ListDetailPage(section: "Screen", onBack: onBack) {
            VStack(alignment: .leading, spacing: 8) {
                if let app { Chip(text: app, tint: .purple) }
                Text(title).font(.system(size: 20, weight: .bold)).textSelection(.enabled)
                if let at { Text(at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary) }
                if let ref { RecordIDLine(ref: ref) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardMaterial()
            CardSection(title: "Captured text") {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
