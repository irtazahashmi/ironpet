import AppKit
import Combine
import IronPetCore
import IronPetKit
import SwiftUI

/// One user-defined dashboard in the ironpet window: the view its script builds, drawn with native components. It runs the script again
/// when the dashboard's data, code or approval changes, so a value an automation posts shows without reopening.
struct DashboardPage: View {
    let id: String
    @ObservedObject var dashboards: DashboardsAPI
    /// Shows the chat, for a click that sent the pet a prompt or asked to open it.
    var onOpenChat: () -> Void
    /// The dashboard whose icon picker is open. Set by the sidebar's context menu, cleared when the picker closes.
    @Binding var pickingIcon: String?

    @State private var view: RemoteDashboardView?
    @State private var generation = 0
    @State private var showApproval = false
    @State private var confirmDelete = false
    @State private var notice: String?
    @State private var detail: DashboardDetail?
    @State private var asked: Set<String> = []

    private var dashboard: RemoteDashboard? { dashboards.list().first { $0.id == id } }

    var body: some View {
        Group {
            if let dashboard {
                page(dashboard)
            } else {
                // Deleted elsewhere while open.
                Color.clear
            }
        }
        .onReceive(dashboards.objectWillChange.debounce(for: .milliseconds(200), scheduler: RunLoop.main)) { _ in generation += 1 }
        .task(id: "\(id)#\(generation)") { await reload() }
    }

    private func page(_ dashboard: RemoteDashboard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = view?.error {
                    errorCard(error)
                } else if let root = view?.root {
                    DashboardNodeView(node: root, onAction: click)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
                }
                if let notice { Text(notice).font(.system(size: 11)).foregroundStyle(.orange) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageHeader(dashboard.title) { controls(dashboard) }
        .sheet(isPresented: $showApproval) { approvalSheet(dashboard) }
        .confirmationDialog("Delete \(dashboard.title)?", isPresented: $confirmDelete) {
            Button("Delete dashboard", role: .destructive) { try? dashboards.delete(id) }
        } message: {
            Text("Its icon and its saved data are removed. Automations that post to it stop working.")
        }
    }

    private func controls(_ dashboard: RemoteDashboard) -> some View {
        HStack(spacing: 8) {
            if let updated = view?.updated {
                Text("Updated \(updated.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { generation += 1 } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Run the dashboard again")
            Menu {
                Button { pickingIcon = id } label: { Label("Change icon…", systemImage: "star") }
                Button { editCode() } label: { Label("Edit code…", systemImage: "doc.text") }
                Button { Task { await openApproval() } } label: { Label("Capabilities…", systemImage: "checkmark.shield") }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete dashboard…", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .popover(isPresented: Binding(get: { pickingIcon == id }, set: { if !$0 { pickingIcon = nil } }), arrowEdge: .bottom) {
                    DashboardIconPicker(dashboards: dashboards, dashboard: dashboard, onClose: { pickingIcon = nil })
                }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This dashboard's code failed", systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            Text(message).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Text("Ask the pet to fix it, or edit the code.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Running

    private func reload() async {
        guard let current = try? await dashboards.view(id) else { return }
        view = current
        // The first time a dashboard that asks for something is opened, or after an edit adds a request, ask once.
        if current.dashboard.approval == "pending", !asked.contains(signature(current.dashboard)) {
            asked.insert(signature(current.dashboard))
            await openApproval()
        }
    }

    private func signature(_ d: RemoteDashboard) -> String { d.capabilities.filter(\.isNew).map(\.kind).joined(separator: ",") + "|" + d.capabilities.map(\.kind).joined(separator: ",") }

    private func click(_ action: String) {
        Task {
            guard let result = try? await dashboards.click(DashboardClickRequest(id: id, handler: action)) else { return }
            notice = result.error
            for effect in result.effects { perform(effect) }
        }
    }

    private func perform(_ effect: RemoteDashboardEffect) {
        switch effect.kind {
        case "chat": onOpenChat()
        case "open":
            if let text = effect.value, let url = URL(string: text) { NSWorkspace.shared.open(url) }
        case "file":
            if let path = effect.value { DashboardFiles.open(path) }
        default: break
        }
    }

    private func editCode() {
        guard let file = dashboards.scriptFile(id) else { return }
        NSWorkspace.shared.open(file)
    }

    // MARK: Approval

    private func openApproval() async {
        detail = try? dashboards.get(id)
        showApproval = detail != nil
    }

    @ViewBuilder private func approvalSheet(_ dashboard: RemoteDashboard) -> some View {
        DashboardApprovalSheet(dashboard: dashboard, decidedBefore: detail?.decided ?? false, onApprove: {
            try? dashboards.approve(id)
            showApproval = false
        }, onDeny: {
            try? dashboards.deny(id)
            showApproval = false
        })
    }
}

/// "Add dashboard X?" for a new dashboard, "Allow more for X?" when an edit asks for more. Every capability is listed, and the new
/// ones are marked, so the user sees what changes. Nothing the dashboard asks for runs before Approve.
struct DashboardApprovalSheet: View {
    let dashboard: RemoteDashboard
    /// The user decided on this dashboard before, so this is an edit.
    let decidedBefore: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    private var hasNew: Bool { dashboard.capabilities.contains(where: \.isNew) }
    private var isEdit: Bool { decidedBefore && hasNew }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: dashboard.icon).font(.system(size: 22)).foregroundStyle(DashboardColors.color(dashboard.color))
                    .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 10).fill(DashboardColors.color(dashboard.color).opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEdit ? "Allow more for \"\(dashboard.title)\"?" : dashboard.capabilities.isEmpty ? "Add dashboard \"\(dashboard.title)\"?" : "Add dashboard \"\(dashboard.title)\"?")
                        .font(.system(size: 15, weight: .semibold))
                    Text(isEdit ? "This dashboard's code changed and it now asks for more. The other capabilities were approved before."
                         : "The pet made this dashboard. It runs only what you allow here. Until you approve, none of it runs.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(dashboard.capabilities.enumerated()), id: \.element.kind) { index, capability in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Self.symbol(capability.kind)).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(capability.title).font(.system(size: 13, weight: .semibold))
                                if capability.isNew { Text("New").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.orange)).foregroundStyle(.black) }
                            }
                            Text(capability.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(capability.isNew ? Color.orange.opacity(0.10) : Color.clear)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(SharedTheme.card))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(isEdit ? "Deny keeps what you approved before. The new capabilities stay off." : "Deny adds the dashboard with none of these.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Deny", action: onDeny).keyboardShortcut(.cancelAction)
                Button("Approve", action: onApprove).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "run": return "terminal"
        case "network": return "network"
        case "read": return "externaldrive"
        case "write": return "pencil"
        case "prompt": return "bubble.left.and.text.bubble.right"
        default: return "questionmark"
        }
    }
}

/// The popover that changes a dashboard's icon and colour. A choice shows in the sidebar at once. Cancel puts the old one back.
struct DashboardIconPicker: View {
    @ObservedObject var dashboards: DashboardsAPI
    let dashboard: RemoteDashboard
    let onClose: () -> Void

    @State private var query = ""
    @State private var original: (icon: String, color: String)?
    @State private var chosenIcon: String?
    @State private var chosenColor: String?

    private var icon: String { chosenIcon ?? dashboard.icon }
    private var color: String { chosenColor ?? dashboard.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(DashboardColors.color(color))
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 9).fill(DashboardColors.color(color).opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(dashboard.title).font(.system(size: 13, weight: .semibold))
                    Text("Icon and colour in the sidebar and on the iPhone").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            TextField("Search symbols", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if query.isEmpty {
                        header("Suggested")
                        grid(DashboardSymbols.suggested.map(\.symbol))
                        header("All symbols")
                    }
                    grid(DashboardSymbols.matching(query).map(\.symbol))
                    if !query.isEmpty && DashboardSymbols.matching(query).isEmpty { Text("No symbol matches").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            .frame(height: 210)
            header("Colour")
            HStack(spacing: 8) {
                ForEach(DashboardColors.names, id: \.self) { name in
                    Button { pick(color: name) } label: {
                        Circle().fill(DashboardColors.color(name)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: color == name ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain).accessibilityLabel(name)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { restore(); onClose() }.keyboardShortcut(.cancelAction)
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(14).frame(width: 340)
        .onAppear { original = (dashboard.icon, dashboard.color) }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func grid(_ symbols: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                Button { pick(icon: symbol) } label: {
                    Image(systemName: symbol).font(.system(size: 14)).frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 7).fill(icon == symbol ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain).help(symbol).accessibilityLabel(symbol)
            }
        }
    }

    private func pick(icon: String? = nil, color: String? = nil) {
        if let icon { chosenIcon = icon }
        if let color { chosenColor = color }
        try? dashboards.setAppearance(id: dashboard.id, icon: icon, color: color)
    }

    private func restore() {
        guard let original, chosenIcon != nil || chosenColor != nil else { return }
        try? dashboards.setAppearance(id: dashboard.id, icon: original.icon, color: original.color)
    }
}

/// What a click on a file in a dashboard does. A document opens in its app. An application, a script or anything executable only
/// shows in Finder, so a dashboard cannot start a program by naming it.
enum DashboardFiles {
    static let revealOnly: Set<String> = ["app", "command", "sh", "zsh", "bash", "pkg", "dmg", "terminal", "workflow", "scpt", "action", "jar", "exe"]

    static func open(_ rawPath: String) {
        let path = (rawPath as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        if shouldOpen(path) { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    static func shouldOpen(_ path: String) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        if revealOnly.contains(ext) { return false }
        if !directory.boolValue, FileManager.default.isExecutableFile(atPath: path) { return false }
        return true
    }
}
