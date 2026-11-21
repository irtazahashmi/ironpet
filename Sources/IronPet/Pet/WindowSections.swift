import AppKit
import IronPetCore
import SwiftUI

/// The Actions section: tricks Ghost does on request. It is a grid of buttons, not a list, so it has no search or detail
/// page; it shares the title row and the column width of the lists.
struct ActionsSection: View {
    let onTrick: (PetController.Trick) -> Void

    var body: some View {
        ListScreen(title: IronPetSection.actions.title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make \(SettingsAPI.live.config.pet.name) do something")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(PetController.Trick.allCases, id: \.self) { trick in
                            TrickTile(trick: trick) { onTrick(trick) }
                        }
                    }
                }
                .padding(ListScreenMetrics.gutter)
                .listColumn()
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// What the Agents search looks at: the project, the prompt and what the agent is doing or did.
enum AgentsSearch {
    static func filter(_ sessions: [AgentSession], query: String) -> [AgentSession] {
        ListSearch.filter(sessions, query: query, title: \.workspaceName, description: description(of:))
    }

    /// The row's one-line description: the prompt, or the summary of a finished turn.
    static func description(of session: AgentSession) -> String? {
        session.prompt ?? session.summary ?? session.detail
    }
}

/// The Agents section: watched sessions, grouped by what they need. Clicking one shows it in full.
struct AgentsSection: View {
    @ObservedObject var agents: AgentsAPI
    @State private var search = ""
    @State private var nav = ListNavigation<String>()

    var body: some View {
        ListScreen(title: IronPetSection.agents.title, search: $search, detailOpen: nav.opened != nil, trailing: {
            HStack(spacing: 4) {
                ForEach([AgentStatus.needsInput, .running, .failed, .done], id: \.self) { status in
                    let count = agents.sessions.filter { $0.status == status }.count
                    if count > 0 { CountChip(count: count, color: status.tint) }
                }
            }
        }) {
            if let id = nav.opened {
                detail(id)
            } else {
                list
            }
        }
    }

    private var sections: [(title: String, sessions: [AgentSession])] {
        let all = AgentsSearch.filter(agents.sessions, query: search)
        return [
            ("Needs you", all.filter { $0.status == .needsInput }),
            ("Working", all.filter { $0.status == .running }),
            ("Finished", all.filter { $0.status == .done || $0.status == .failed }),
        ].filter { !$0.sessions.isEmpty }
    }

    @ViewBuilder private var list: some View {
        if agents.sessions.isEmpty {
            EmptyState(symbol: "moon.zzz", title: "No agents running",
                       detail: "Cursor and Claude Code sessions show up here.")
        } else if sections.isEmpty {
            NoMatches()
        } else {
            ListScroll {
                ForEach(sections, id: \.title) { section in
                    if section.title == "Finished" {
                        SectionHeader(section.title, action: "Clear finished") { agents.acknowledgeAll() }
                    } else {
                        ListGroupTitle(section.title)
                    }
                    ForEach(section.sessions) { session in
                        SessionRow(session: session,
                                   onOpen: { nav.open(session.id) },
                                   onJump: { try? agents.focus(session.id) },
                                   onDismiss: { try? agents.acknowledge(session.id) })
                    }
                }
            }
        }
    }

    @ViewBuilder private func detail(_ id: String) -> some View {
        if let session = agents.sessions.first(where: { $0.id == id }) {
            ListDetailPage(section: "Agents", onBack: { nav.close() }) {
                HStack(spacing: 8) {
                    StatusIcon(status: session.status).frame(width: 20, height: 20)
                    Text(session.workspaceName).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
                    SourceTag(source: session.source)
                }
                HStack(spacing: 8) {
                    Button { try? agents.focus(session.id) } label: { Label(Editors.label(for: session), systemImage: "arrow.up.forward.app") }
                    if session.status == .done || session.status == .failed {
                        Button("Dismiss") { try? agents.acknowledge(session.id); nav.close() }
                    }
                }
                .buttonStyle(.bordered)
                DetailField(label: "Status", value: session.status.title)
                if let prompt = session.prompt { DetailField(label: "Prompt", value: prompt) }
                if let activity = session.detail { DetailField(label: "Doing now", value: activity) }
                if let reply = session.lastResponse { DetailField(label: "Last reply", value: reply) }
                if !session.editedFiles.isEmpty { DetailField(label: "Files edited this turn", value: session.editedFiles.joined(separator: "\n")) }
                if let workspace = session.origin.workspace { DetailField(label: "Workspace", value: workspace) }
                DetailField(label: "Turn started", value: session.turnStartedAt.formatted(date: .abbreviated, time: .shortened))
                DetailField(label: "Last update", value: session.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .onExitCommand { nav.close() }
        } else {
            // The session was dismissed while it was open.
            Color.clear.onAppear { nav.close() }
        }
    }
}

/// What the Alerts search looks at: the title and the line under it.
enum AlertsSearch {
    static func filter(_ signals: [Signal], query: String) -> [Signal] {
        ListSearch.filter(signals, query: query, title: \.title, description: \.subtitle)
    }
}

/// The Alerts section: what automations reported, newest first. Clicking one shows its full text and links.
struct AlertsSection: View {
    @ObservedObject var alerts: AlertsAPI
    let onAsk: (String) -> Void
    @State private var search = ""
    @State private var nav = ListNavigation<String>()

    var body: some View {
        ListScreen(title: IronPetSection.alerts.title, search: $search, detailOpen: nav.opened != nil, trailing: {
            if !alerts.alerts.isEmpty {
                Button("Clear all") { alerts.dismissAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }) {
            if let id = nav.opened {
                detail(id)
            } else {
                list
            }
        }
    }

    private func open(_ signal: Signal) {
        if let url = signal.url { NSWorkspace.shared.open(url) }
        try? alerts.dismiss(signal.id)
    }

    @ViewBuilder private var list: some View {
        let shown = AlertsSearch.filter(alerts.alerts, query: search)
        if alerts.alerts.isEmpty {
            EmptyState(symbol: "bell.slash", title: "No alerts",
                       detail: "Alerts from your automations show up here, such as CI, reviews and errors.")
        } else if shown.isEmpty {
            NoMatches()
        } else {
            ListScroll {
                ForEach(shown) { signal in
                    SignalRow(signal: signal,
                              onShow: { nav.open(signal.id) },
                              onOpen: { open(signal) },
                              onAsk: signal.ask.map { prompt in { onAsk(prompt) } },
                              onDismiss: { try? alerts.dismiss(signal.id) })
                }
            }
        }
    }

    @ViewBuilder private func detail(_ id: String) -> some View {
        if let signal = alerts.alerts.first(where: { $0.id == id }) {
            ListDetailPage(section: "Alerts", onBack: { nav.close() }) {
                Label(signal.label, systemImage: signal.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SignalRow.color(signal))
                Text(signal.title).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
                HStack(spacing: 8) {
                    if signal.url != nil { Button("Open") { open(signal); nav.close() } }
                    if let prompt = signal.ask {
                        Button { onAsk(prompt) } label: { Label("Ask \(SettingsAPI.live.config.pet.name)", systemImage: "sparkles") }
                    }
                    Button("Dismiss") { try? alerts.dismiss(signal.id); nav.close() }
                }
                .buttonStyle(.bordered)
                if !signal.subtitle.isEmpty { DetailField(label: "Summary", value: signal.subtitle) }
                if let text = signal.detail, !text.isEmpty { DetailField(label: "Details", value: text) }
                if let url = signal.url { DetailField(label: "Link", value: url.absoluteString) }
                ForEach(Array(signal.links.enumerated()), id: \.offset) { _, link in
                    DetailField(label: link.title, value: link.ref)
                }
                DetailField(label: "Received", value: signal.date.formatted(date: .abbreviated, time: .shortened))
            }
            .onExitCommand { nav.close() }
        } else {
            // The alert was dismissed while it was open.
            Color.clear.onAppear { nav.close() }
        }
    }
}

private struct TrickTile: View {
    let trick: PetController.Trick
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: trick.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 26)
                Text(trick.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(hovering ? 0.12 : 0.06), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Rows

private struct SessionRow: View {
    let session: AgentSession
    let onOpen: () -> Void
    let onJump: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ListRow(title: session.workspaceName, description: AgentsSearch.description(of: session), emphasized: true, onOpen: onOpen,
                leading: { StatusIcon(status: session.status).frame(width: 18, height: 18).padding(.top, 1) },
                extra: {
                    if let detail = session.detail, session.status == .needsInput || session.status == .running {
                        ActivityLabel(detail: detail, status: session.status)
                    }
                },
                trailing: { hovering in
                    HStack(spacing: 6) {
                        SourceTag(source: session.source)
                        if hovering {
                            actions
                        } else {
                            Elapsed(session: session)
                        }
                    }
                })
        .help(Editors.label(for: session))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if session.status == .done || session.status == .failed {
                IconButton(symbol: "xmark", help: "Dismiss", action: onDismiss)
            }
            IconButton(symbol: "arrow.up.forward.app", help: Editors.label(for: session),
                       action: onJump)
        }
    }
}

private struct SignalRow: View {
    let signal: Signal
    let onShow: () -> Void
    let onOpen: () -> Void
    let onAsk: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        ListRow(title: signal.title, description: signal.subtitle, onOpen: onShow,
                leading: { ListRowIcon(symbol: signal.symbol, color: Self.color(signal)) },
                extra: {
                    if signal.url != nil || onAsk != nil {
                        HStack(spacing: 6) {
                            if signal.url != nil { Button("Open", action: onOpen) }
                            if let onAsk {
                                Button(action: onAsk) { Label("Ask \(SettingsAPI.live.config.pet.name)", systemImage: "sparkles") }
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                    }
                },
                trailing: { hovering in
                    HStack(spacing: 6) {
                        Text(signal.label).font(.caption.weight(.semibold)).foregroundStyle(Self.color(signal))
                        if hovering {
                            IconButton(symbol: "xmark", help: "Dismiss", action: onDismiss)
                        } else {
                            Text(signal.date, style: .relative)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                })
    }

    static func color(_ signal: Signal) -> Color {
        switch signal.mood {
        case .failed: return .red
        case .needsInput: return .orange
        default: return .green
        }
    }
}

// MARK: - Pieces

private struct StatusIcon: View {
    let status: AgentStatus

    var body: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.8)
        case .needsInput:
            Image(systemName: "hand.raised.fill").foregroundStyle(status.tint).symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(status.tint)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(status.tint)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

private struct SourceTag: View {
    let source: AgentSource

    var body: some View {
        Text(source.displayName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// Live time for running turns, "ago" for everything else.
private struct Elapsed: View {
    let session: AgentSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let running = session.status == .running || session.status == .needsInput
            let since = running ? session.turnStartedAt : session.updatedAt
            Text(Self.format(context.date.timeIntervalSince(since)) + (running ? "" : " ago"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(running ? session.status.tint : Color.secondary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// The tool the agent is using right now, or what it is waiting on.
private struct ActivityLabel: View {
    let detail: String
    let status: AgentStatus

    var body: some View {
        Label {
            Text(detail).lineLimit(2)
        } icon: {
            Image(systemName: status == .needsInput ? "questionmark.bubble" : Self.symbol(for: detail))
        }
        .font(.caption)
        .foregroundStyle(status == .needsInput ? AnyShapeStyle(status.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
    }

    static func symbol(for tool: String) -> String {
        let name = tool.lowercased()
        if name.hasPrefix("mcp") { return "puzzlepiece.extension" }
        if ["shell", "bash", "terminal"].contains(where: name.contains) { return "terminal" }
        if ["edit", "write", "replace", "delete", "notebook"].contains(where: name.contains) { return "pencil" }
        if ["read", "view"].contains(where: name.contains) { return "doc.text" }
        if ["grep", "glob", "search", "find", "ls"].contains(where: name.contains) { return "magnifyingglass" }
        if ["web", "fetch"].contains(where: name.contains) { return "globe" }
        if ["task", "agent"].contains(where: name.contains) { return "person.2" }
        if name.contains("todo") { return "checklist" }
        return "gearshape"
    }
}

private struct CountChip: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// A section title with one action for the whole section, such as Clear finished or Add all.
struct SectionHeader: View {
    let title: String
    let action: String
    let help: String?
    let perform: () -> Void

    init(_ title: String, action: String, help: String? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.action = action
        self.help = help
        self.perform = perform
    }

    var body: some View {
        HStack {
            SectionTitle(title)
            Spacer()
            Button(action, action: perform)
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .help(help ?? action)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AgentStatus {
    var title: String {
        switch self {
        case .needsInput: return "Needs you"
        case .failed: return "Failed"
        case .done: return "Done"
        case .running: return "Working"
        case .idle: return "Idle"
        }
    }

    var symbol: String {
        switch self {
        case .needsInput: return "hand.raised.fill"
        case .failed: return "xmark.octagon.fill"
        case .done: return "checkmark.circle.fill"
        case .running: return "circle.dotted"
        case .idle: return "circle"
        }
    }

    var bubbleTint: BubbleTint {
        switch self {
        case .needsInput: return .orange
        case .failed: return .red
        case .done: return .green
        case .running: return .accent
        case .idle: return .secondary
        }
    }

    var tint: Color { bubbleTint.color }
}
