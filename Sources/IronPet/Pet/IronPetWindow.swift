import AppKit
import IronPetKit
import IronPetCore
import SwiftUI

/// A page of the ironpet window, in sidebar order.
enum IronPetSection: String, CaseIterable, Identifiable {
    case chat, agents, alerts, notifications, inbox, transcripts, screen, actions, automations, memory, today
    /// A user-defined dashboard. Never a row of its own: each dashboard is a `SidebarRow` with this section and its own id, and
    /// `IronPetWindowModel.dashboardID` says which one is open.
    case dashboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .agents: return "Agents"
        case .alerts: return "Alerts"
        case .notifications: return "Notifications"
        case .inbox: return "Inbox"
        case .transcripts: return "Transcripts"
        case .screen: return "Screen"
        case .actions: return "Actions"
        case .automations: return "Automations"
        case .memory: return "Memory"
        case .today: return "Today"
        case .dashboard: return "Dashboard"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return SharedSymbols.chat
        case .agents: return SharedSymbols.agents
        case .alerts: return SharedSymbols.alerts
        case .notifications: return "tray"
        case .inbox: return SharedSymbols.tasks
        case .transcripts: return SharedSymbols.meetings
        case .screen: return SharedSymbols.screen
        case .actions: return "sparkles"
        case .automations: return SharedSymbols.automations
        case .memory: return SharedSymbols.memory
        case .today: return "sun.horizon"
        case .dashboard: return "square.grid.2x2"
        }
    }

    /// The sections the sidebar lists, in order. Chat, Transcripts and Automations need their backing object. Today
    /// is listed only while a brief or recap automation is on, and comes last so the other rows keep their ⌘N.
    /// Agents is listed only while the device tracks agents. This filters the available sections and leaves the user's own
    /// hide choice in `SidebarLayout` alone, so turning tracking on again brings back what they had.
    static func shown(chat: Bool, transcripts: Bool, automations: Bool, today: Bool = false,
                      notifications: Bool = true, agents: Bool = true) -> [IronPetSection] {
        allCases.filter {
            $0 != .dashboard && ($0 != .chat || chat) && ($0 != .transcripts || transcripts) && ($0 != .automations || automations)
                && ($0 != .today || today) && ($0 != .notifications || notifications) && ($0 != .agents || agents)
        }
    }

    /// The section to open when `section` was asked for: Chat in place of Agents while tracking is off, so no link, bubble or
    /// shortcut lands on an empty Agents page.
    func opened(agentsTracked: Bool) -> IronPetSection {
        self == .agents && !agentsTracked ? .chat : self
    }

    /// The section ⌘1 to ⌘9 select: the Nth row of `sections`. Nil for ⌘0, any other key, or a digit past the last row.
    static func forShortcut(_ characters: String?, in sections: [IronPetSection]) -> IronPetSection? {
        guard let characters, characters.count == 1, let digit = Int(characters), (1...9).contains(digit),
              digit <= sections.count else { return nil }
        return sections[digit - 1]
    }

    /// The shortcut that selects this section, such as "⌘4"; nil past the ninth row.
    func shortcutLabel(in sections: [IronPetSection]) -> String? {
        guard let index = sections.firstIndex(of: self), index < 9 else { return nil }
        return "⌘\(index + 1)"
    }

    /// The tooltip of a sidebar row or rail icon: the name and its ⌘N shortcut.
    func hint(in sections: [IronPetSection]) -> String {
        guard let shortcut = shortcutLabel(in: sections) else { return title }
        return "\(title) (\(shortcut))"
    }

    /// The sections that show what a bubble would announce, so bubbles wait while one is open. The others leave them
    /// visible, so an approval is not missed while reading a transcript or editing an automation.
    var hidesBubbles: Bool { [.chat, .agents, .alerts, .notifications, .inbox, .actions, .today].contains(self) }

    /// Agents that need the user win; otherwise alerts when there are some and no agent is working, then the Inbox when it
    /// has items.
    @MainActor static func needingAttention(agents: AgentsAPI, alerts: AlertsAPI, tasks: TasksAPI, agentsTracked: Bool = true) -> IronPetSection {
        guard agentsTracked else {
            if !alerts.alerts.isEmpty { return .alerts }
            return tasks.suggestions.isEmpty ? .chat : .inbox
        }
        if agents.sessions.contains(where: { $0.status == .needsInput || $0.status == .failed }) { return .agents }
        let idle = agents.sessions.allSatisfy { $0.status != .running }
        if !alerts.alerts.isEmpty, idle { return .alerts }
        if idle, !tasks.suggestions.isEmpty { return .inbox }
        return .agents
    }
}

@MainActor
final class IronPetWindowModel: ObservableObject {
    static let sidebarCollapsedKey = "ironpetSidebarCollapsed"
    static let sidebarWidthKey = "ironpetSidebarWidth"
    /// The expanded sidebar is 156 to 300 pt wide, 156 by default. At 156 the longest row ("Transcripts" or
    /// "Automations") fits with a badge.
    static let minSidebarWidth: CGFloat = 156
    static let maxSidebarWidth: CGFloat = 300
    /// The rail is as wide as the row of traffic lights: they span x 9 to 69, so it keeps the same 9 pt on the right.
    static let railWidth: CGFloat = 78
    /// Dragging the sidebar's edge below this width collapses it to the rail (halfway between rail and minimum);
    /// dragging a rail past it expands the sidebar.
    static let snapWidth: CGFloat = (railWidth + minSidebarWidth) / 2

    /// The width the sidebar has while the edge is dragged: where the pointer is, between the rail and the maximum.
    static func dragWidth(start: CGFloat, delta: CGFloat) -> CGFloat {
        min(max(start + delta, railWidth), maxSidebarWidth)
    }

    /// Whether a sidebar of this width shows the rail instead of the rows.
    static func showsRail(atWidth width: CGFloat) -> Bool { width < snapWidth }

    @Published var section: IronPetSection = .chat
    /// The dashboard shown while `section` is `.dashboard`.
    @Published var dashboardID: String?
    /// The dashboard whose icon picker is open, from the sidebar's context menu.
    @Published var pickingIconFor: String?
    /// Whether the Today row is listed: a brief or recap automation is on. Leaving it hidden moves off the page.
    @Published var todayShown = false {
        didSet { if !todayShown, section == .today { section = .chat } }
    }
    /// Whether this device tracks coding agents. Off hides the Agents row and leaves the page.
    @Published var agentsTracked = true {
        didSet { if !agentsTracked, section == .agents { section = .chat } }
    }
    /// The page Today shows: the morning brief or the recap.
    @Published var briefKind: Brief.Kind = .brief
    /// A notification a bubble opened. The Notifications page expands it, then clears it.
    @Published var focusNotification: String?
    @Published var focusMeeting: String?
    /// True when the sidebar shows only the section icons. Saved, so it survives closing the window and restarting.
    @Published var sidebarCollapsed: Bool {
        didSet {
            defaults.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey)
            clearRailTip()
        }
    }
    /// Width of the expanded sidebar; what the user last dragged it to. Saved.
    @Published var sidebarWidth: CGFloat {
        didSet { defaults.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey) }
    }
    /// The order of the sidebar's sections and the ones the user hid. Saved on this Mac.
    @Published private(set) var layout: SidebarLayout {
        didSet { layout.save(to: defaults) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = SidebarLayout(defaults: defaults)
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarCollapsedKey)
        let saved = defaults.double(forKey: Self.sidebarWidthKey)
        sidebarWidth = saved == 0 ? Self.minSidebarWidth : min(max(CGFloat(saved), Self.minSidebarWidth), Self.maxSidebarWidth)
    }

    func toggleSidebar() { sidebarCollapsed.toggle() }

    // MARK: Sidebar arrangement

    /// The rows the sidebar draws, in the user's order, from the sections that can be listed. ⌘1 to ⌘9 index into this.
    func sidebarRows(_ available: [IronPetSection]) -> [IronPetSection] { layout.visible(available) }

    func setSectionHidden(_ section: IronPetSection, _ hidden: Bool) { layout.setHidden(section, hidden) }

    func moveRows(from offsets: IndexSet, to destination: Int, in available: [IronPetSection]) {
        layout.moveVisible(from: offsets, to: destination, in: available)
    }

    func moveRow(_ section: IronPetSection, before target: IronPetSection?, in available: [IronPetSection]) {
        layout.move(section, before: target, in: available)
    }

    /// Shows a user-defined dashboard.
    func open(dashboard id: String) {
        dashboardID = id
        section = .dashboard
    }

    /// The id of the sidebar row that is selected: a section's raw value, or `dashboard:<id>`.
    var selectedRowID: String { section == .dashboard ? SidebarRow.dashboardRowID(dashboardID ?? "") : section.rawValue }

    /// A bubble was clicked: show the Notifications page with this entry open.
    func openNotification(_ id: String) {
        focusNotification = id
        section = .notifications
    }

    /// The width of the column as it is now: the rail's, or the sidebar's own.
    var columnWidth: CGFloat { sidebarCollapsed ? Self.railWidth : sidebarWidth }

    /// The drag ended with the edge at `width`: collapse to the rail below the snap width, otherwise expand to it.
    func endDrag(atWidth width: CGFloat) {
        if Self.showsRail(atWidth: width) {
            sidebarCollapsed = true
        } else {
            sidebarWidth = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
            sidebarCollapsed = false
        }
    }

    // MARK: Rail labels

    /// How long the pointer rests on a rail icon before its label shows.
    static var railTipDelay: Duration = .milliseconds(400)
    /// The label to draw beside a rail icon, or nil. A native `.help` tooltip does not show while ironpet is not the
    /// active app, which is the usual state of this floating window, so the rail draws its own label.
    @Published private(set) var railTip: RailTip?
    private var railTipTask: Task<Void, Never>?

    /// The pointer entered or left a rail icon. Entering shows the label after `railTipDelay`; leaving hides it.
    func hoverRail(_ tip: RailTip, hovering: Bool) {
        railTipTask?.cancel()
        guard hovering else {
            railTip = nil
            return
        }
        railTipTask = Task { [weak self] in
            try? await Task.sleep(for: Self.railTipDelay)
            guard !Task.isCancelled else { return }
            self?.railTip = tip
        }
    }

    /// Hides the label and cancels one that is still waiting: a click, or the sidebar changing state.
    func clearRailTip() {
        railTipTask?.cancel()
        railTip = nil
    }
}

/// Reorders the rail while an icon is dragged over another: the dragged icon takes the place of the one under it.
private struct RailDrop: DropDelegate {
    let target: IronPetSection
    let model: IronPetWindowModel
    let available: [IronPetSection]
    @Binding var dragged: IronPetSection?

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        let rows = model.sidebarRows(available)
        guard let from = rows.firstIndex(of: dragged), let to = rows.firstIndex(of: target) else { return }
        // Dragging down puts it after the target, dragging up before it.
        let before = from < to ? rows.indices.contains(to + 1) ? rows[to + 1] : nil : target
        model.moveRow(dragged, before: before, in: available)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// One row of the sidebar or one icon of the rail. Built-in sections and user-defined dashboards share this list, each with a stable
/// `id` (`inbox`, `dashboard:work`). The user's order and hiding apply to the built-in sections only. The dashboards follow them.
struct SidebarRow: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let section: IronPetSection
    var dashboardID: String?
    /// The icon's colour. Nil draws it in the sidebar's own style.
    var tint: String?
    var count = 0

    static func dashboardRowID(_ id: String) -> String { "dashboard:\(id)" }

    static func section(_ section: IronPetSection, count: Int = 0) -> SidebarRow {
        SidebarRow(id: section.rawValue, title: section.title, symbol: section.symbol, section: section, count: count)
    }

    static func dashboard(_ d: RemoteDashboard) -> SidebarRow {
        SidebarRow(id: dashboardRowID(d.id), title: d.title, symbol: d.icon, section: .dashboard, dashboardID: d.id, tint: d.color, count: d.count ?? 0)
    }

    /// The rows to list: `sections` in their order, then the dashboards in theirs.
    static func rows(sections: [IronPetSection], dashboards: [RemoteDashboard], count: (IronPetSection) -> Int) -> [SidebarRow] {
        sections.map { .section($0, count: count($0)) } + dashboards.map(SidebarRow.dashboard)
    }
}

/// The text of a rail label and where its icon is, in the window's coordinates.
struct RailTip: Equatable {
    let name: String
    let shortcut: String?
    let frame: CGRect
}

struct IronPetWindowView: View {
    @ObservedObject var model: IronPetWindowModel
    @ObservedObject var agents: AgentsAPI
    @ObservedObject var alerts: AlertsAPI
    @ObservedObject var tasks: TasksAPI
    /// The user-defined dashboards. The placeholder in previews and tests that have none.
    @ObservedObject var dashboards: DashboardsAPI = .unavailable
    /// The Notifications page. Left at `empty` in tests and previews that do not show it; its row is hidden then.
    @ObservedObject var notifications = NotificationsModel.empty
    /// Nil in previews and tests that do not show it; its row is hidden then.
    var chat: ChatViewModel?
    var meetings: MeetingsAPI?
    /// Nil in previews, which cannot build the Automations section; its row is hidden then.
    var settings: SettingsModel?
    /// The Today page's content. Nil in tests that do not show it.
    var brief: BriefModel?
    let actions: SessionActions
    @ObservedObject private var config = SettingsAPI.live
    @ObservedObject private var memoryModel = MemorySectionModel.shared

    /// A source chip under a fact: open the chat, meeting or capture it came from.
    private func openMemorySource(_ source: MemorySource) {
        switch source.kind {
        case .meeting:
            if let folder = source.target { model.focusMeeting = folder }
            model.section = .transcripts
        case .task: break
        case .screen: model.section = .screen
        case .automation: model.section = .automations
        case .chat: model.section = .chat
        case .user, .other: break
        }
    }

    var body: some View {
        // One background under the sidebar and the page; the sidebar is glass over it.
        ZStack {
            ChatBackdrop()
            HStack(spacing: 0) {
                sidebarColumn
                // The edge is a drag handle, wider than the line it sits on.
                Divider().overlay {
                    SidebarResizeHandle(
                        onBegin: { dragStart = liveWidth ?? model.columnWidth; model.clearRailTip() },
                        onDrag: { delta in
                            guard let start = dragStart else { return }
                            liveWidth = IronPetWindowModel.dragWidth(start: start, delta: delta)
                        },
                        onEnd: {
                            if let width = liveWidth { model.endDrag(atWidth: width) }
                            liveWidth = nil
                            dragStart = nil
                        })
                    .frame(width: 9)
                }
                .zIndex(1) // above the detail view, so the handle's wider hit area is not covered
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .coordinateSpace(name: RailHover.space)
        // Over the page, outside the rail, which clips its own content.
        .overlay(alignment: .topLeading) {
            if collapsed, let tip = model.railTip {
                RailLabel(tip: tip)
                    .offset(x: IronPetWindowModel.railWidth - 2, y: tip.frame.minY)
                    .frame(height: tip.frame.height, alignment: .leading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.railTip)
        // The pages the user followed in Memory are forgotten when they leave the section.
        .onChange(of: model.section) { _, section in if section != .memory { memoryModel.showList() } }
        // A dashboard deleted while it is open leaves the user on the Chat page, not on an empty one.
        .onChange(of: dashboards.list().map(\.id)) { _, ids in
            if model.section == .dashboard, let open = model.dashboardID, !ids.contains(open) { model.section = .chat }
        }
    }

    /// Every sidebar row in order: the built-in sections, then the dashboards.
    private var rows: [SidebarRow] {
        SidebarRow.rows(sections: shown, dashboards: dashboards.list(), count: count)
    }

    private func select(_ row: SidebarRow) {
        if let id = row.dashboardID { model.open(dashboard: id) } else { model.section = row.section }
    }

    /// The sections that can be listed, whether or not the user hid them.
    private var available: [IronPetSection] {
        IronPetSection.shown(chat: chat != nil, transcripts: meetings != nil, automations: settings != nil,
                             today: model.todayShown, notifications: notifications !== NotificationsModel.empty,
                             agents: model.agentsTracked)
    }

    /// The rows drawn, in the user's order without the hidden sections.
    private var shown: [IronPetSection] { model.sidebarRows(available) }

    /// Right-click on the sidebar: every section with a check, in the order of the sidebar.
    @ViewBuilder private var sectionMenu: some View {
        ForEach(model.layout.arranged(available)) { section in
            Toggle(section.title, isOn: Binding(
                get: { !model.layout.isHidden(section) },
                set: { model.setSectionHidden(section, !$0) }))
                .disabled(section == SidebarLayout.pinned)
        }
    }

    private var collapsed: Bool { model.sidebarCollapsed }
    /// The column's width while its edge is being dragged; nil otherwise.
    @State private var liveWidth: CGFloat?
    @State private var dragStart: CGFloat?
    /// Whether the column shows the rail: while dragging, whichever side of the snap width the edge is on.
    private var showsRail: Bool { liveWidth.map(IronPetWindowModel.showsRail(atWidth:)) ?? collapsed }

    /// While dragging, the rows never render narrower than their minimum; the rail shows below the snap width.
    private var columnWidth: CGFloat {
        guard let live = liveWidth else { return model.columnWidth }
        return showsRail ? live : max(live, IronPetWindowModel.minSidebarWidth)
    }

    /// The full sidebar or the icon rail, one glass column whose width animates between the two.
    private var sidebarColumn: some View {
        ZStack {
            if showsRail { rail.transition(.opacity) } else { sidebar.transition(.opacity) }
        }
        .frame(width: columnWidth)
        .clipped()
        // The whole column, insets included, is glass over the window background: a half-strength material, so the pattern stays visible through it.
        .background { Rectangle().fill(.ultraThinMaterial).opacity(IronPetGlass.strength) }
        .animation(.easeInOut(duration: 0.2), value: showsRail)
        .animation(.easeInOut(duration: 0.2), value: model.sidebarWidth)
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.selectedRowID }, set: { id in if let row = rows.first(where: { $0.id == id }) { select(row) } })) {
            // Only the built-in rows move. The dashboards follow them in the order the store lists them.
            ForEach(rows.filter { $0.dashboardID == nil }) { row($0) }
                .onMove { model.moveRows(from: $0, to: $1, in: available) }
            ForEach(rows.filter { $0.dashboardID != nil }) { row($0) }
        }
        .contextMenu { sectionMenu }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Room for the traffic lights, which the window draws over this strip.
            Color.clear.frame(height: PageHeaderMetrics.height)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: actions.onSettings) {
                Label("Settings", systemImage: SharedSymbols.settings)
                    .labelStyle(.ironPetSidebar)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .help("Open ironpet Settings (⌘,)")
        }
    }

    /// Only the section icons, in the sidebar's order, under the traffic lights.
    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(rows) { row in
                // A thin line sets the user's dashboards apart from the built-in sections.
                if row.dashboardID != nil, rows.first(where: { $0.dashboardID != nil })?.id == row.id {
                    Divider().frame(width: 28).padding(.vertical, 2)
                }
                let selected = model.selectedRowID == row.id
                let tint = row.tint.map(DashboardColors.color)
                // A tap gesture, not a Button: a Button takes the mouse-down, so `.onDrag` never starts on it.
                Image(systemName: row.symbol)
                    .font(.system(size: 21))
                    .frame(width: 40, height: 38)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10).fill((tint ?? Color.accentColor).opacity(0.28))
                        }
                    }
                    .overlay(alignment: .topTrailing) { railBadge(row.count) }
                    .contentShape(Rectangle())
                    .onTapGesture { model.clearRailTip(); select(row) }
                    .foregroundStyle(tint ?? (selected ? Color.accentColor : Color.primary))
                    .railHover(model, name: row.title, shortcut: row.section == .dashboard ? nil : row.section.shortcutLabel(in: shown))
                    .accessibilityLabel(row.title)
                    .accessibilityAddTraits(.isButton)
                    .blocksWindowDrag()
                    .contextMenu { dashboardMenu(row) }
                    .railReorder(row, model: model, available: available, dragged: $draggedRail)
            }
            Spacer(minLength: 0)
            Button(action: { model.clearRailTip(); actions.onSettings() }) {
                Image(systemName: SharedSymbols.settings).font(.system(size: 21)).frame(width: 40, height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .railHover(model, name: "Settings", shortcut: "⌘,")
            .accessibilityLabel("Settings")
            .padding(.bottom, 10)
        }
        .padding(.top, PageHeaderMetrics.height + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu { sectionMenu }
    }

    @State private var draggedRail: IronPetSection?

    @ViewBuilder private func railBadge(_ count: Int) -> some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: 2, y: -2)
        }
    }

    private func row(_ row: SidebarRow) -> some View {
        Label {
            Text(row.title)
        } icon: {
            Image(systemName: row.symbol).foregroundStyle(row.tint.map(DashboardColors.color) ?? Color.primary)
        }
        .labelStyle(.ironPetSidebar)
        .badge(row.count)
        .tag(row.id)
        .help(row.section == .dashboard ? row.title : shortcutHint(row.section))
        .contextMenu { dashboardMenu(row) }
    }

    /// A dashboard's row offers its icon picker, which opens on the dashboard's page.
    @ViewBuilder private func dashboardMenu(_ row: SidebarRow) -> some View {
        if let id = row.dashboardID {
            Button("Change icon…") { model.clearRailTip(); model.open(dashboard: id); model.pickingIconFor = id }
        }
    }

    private func shortcutHint(_ section: IronPetSection) -> String { section.hint(in: shown) }

    private func count(_ section: IronPetSection) -> Int {
        switch section {
        case .agents: return agents.sessions.count
        case .alerts: return alerts.alerts.count
        case .notifications: return notifications.unread
        case .inbox: return tasks.suggestions.count
        default: return 0
        }
    }

    @ViewBuilder private var detail: some View {
        if model.section == .chat, let chat {
            // The chat draws its own floating header up to the top edge.
            ChatView(session: chat)
        } else {
            VStack(spacing: 0) {
                switch model.section {
                case .chat: EmptyView()
                case .agents: AgentsSection(agents: agents)
                case .alerts: AlertsSection(alerts: alerts, onAsk: actions.onAsk)
                case .notifications:
                    NotificationsSection(model: notifications, focus: $model.focusNotification)
                case .inbox:
                    InboxView(tasks: tasks, onOpenMeeting: { folder in
                        model.focusMeeting = folder
                        model.section = .transcripts
                    }, onOpenChat: actions.onOpenThread)
                case .transcripts:
                    if let meetings {
                        TranscriptsView(meetings: meetings, focus: $model.focusMeeting)
                    }
                case .screen:
                    if let screen = settings?.capture {
                        ScreenSection(model: screen.status, screen: screen, onOpenSettings: actions.onScreenSettings,
                                      onAppear: { screen.refreshStatus() })
                    } else {
                        ScreenSection(model: CaptureStatusModel(), onOpenSettings: actions.onScreenSettings)
                    }
                case .actions: ActionsSection(onTrick: actions.onTrick)
                case .automations:
                    if let settings {
                        AutomationsSettings(model: settings).frame(maxHeight: .infinity)
                    }
                case .memory:
                    MemorySection(model: memoryModel, onOpenSource: openMemorySource, onOpenSettings: actions.onMemorySettings)
                case .today:
                    if let brief {
                        TodayView(model: brief, kind: $model.briefKind, onOpen: actions.onBriefOpen)
                    }
                case .dashboard:
                    if let id = model.dashboardID {
                        DashboardPage(id: id, dashboards: dashboards, onOpenChat: { model.section = .chat }, pickingIcon: $model.pickingIconFor)
                            .id(id)
                    }
                }
            }
            // A photo behind unfilled rows would hide their text; the built-in patterns are faint enough without it.
            .background { if config.config.chat.background == ChatBackground.customID { Rectangle().fill(.thinMaterial) } }
        }
    }
}

/// What the rows and buttons in the window's sections do.
struct SessionActions {
    var onAsk: (String) -> Void
    var onTrick: (PetController.Trick) -> Void
    var onTellGhost: (String) -> Void
    var onOpenThread: (String) -> Void
    var onOpenSession: (String) -> Void
    var onSettings: () -> Void = {}
    /// Opens Settings on the Screen tab.
    var onScreenSettings: () -> Void = {}
    /// Opens Settings on the Memory tab.
    var onMemorySettings: () -> Void = {}
    /// A row of the Today page.
    var onBriefOpen: (Brief.Target) -> Void = { _ in }
    static let none = SessionActions(onAsk: { _ in }, onTrick: { _ in }, onTellGhost: { _ in },
                                     onOpenThread: { _ in }, onOpenSession: { _ in })
}

/// Size of every section header and where its title sits. 52 pt is the height of a macOS unified toolbar (it was 30).
/// The window moves the traffic lights down to the middle of this band (`IronPetPanel.centerWindowButtons`), so the
/// title and the traffic lights share one center line.
enum PageHeaderMetrics {
    static let height: CGFloat = 52
}

/// The title of a section, with the actions that apply to all of it on the right. Every section, and the chat, uses it,
/// so the height and the title's position are the same everywhere. `leading` goes just before the title (the chat's avatar).
struct PageHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .background(FrameReader(role: .title))
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: PageHeaderMetrics.height)
        .background(FrameReader(role: .header))
    }
}

/// Reports where a header and its title were laid out, in window coordinates, so a test can compare sections.
struct PageHeaderFrames: PreferenceKey, Equatable {
    var header: CGRect?
    var title: CGRect?
    static let defaultValue = PageHeaderFrames()
    static func reduce(value: inout PageHeaderFrames, nextValue: () -> PageHeaderFrames) {
        let next = nextValue()
        value.header = value.header ?? next.header
        value.title = value.title ?? next.title
    }
}

struct FrameReader: View {
    enum Role { case header, title }
    let role: Role

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(key: PageHeaderFrames.self,
                                   value: role == .header ? PageHeaderFrames(header: frame) : PageHeaderFrames(title: frame))
        }
    }
}

extension PageHeader where Leading == EmptyView {
    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, leading: { EmptyView() }, trailing: trailing)
    }
}

extension View {
    /// Puts a glass panel at the top of a section, the width of the section, with the window background showing
    /// through it. The section scrolls under the panel. The panel starts at the top of the window, under the
    /// transparent title bar, and is `PageHeaderMetrics.height` tall.
    func pageHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            GlassPanel { PageHeader(title: title, trailing: trailing) }
        }
    }
}

/// How much of the material the sidebar and the headers use: half, so the pattern behind the window shows through the
/// glass instead of blurring away.
enum IronPetGlass {
    static let strength = SharedTheme.chromeStrength
}

/// The glass strip used by every section's header and by the chat header: a material with a hairline below it.
struct GlassPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .background { Rectangle().fill(.ultraThinMaterial).opacity(IronPetGlass.strength) }
            .overlay(alignment: .bottom) {
                // An explicit line: a Divider takes its direction from the container it lands in and turned vertical in the chat's bar.
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
    }
}

/// Reports a rail icon's hover and position to the model, which shows the label.
private struct RailHover: ViewModifier {
    static let space = "ironpetWindow"
    let model: IronPetWindowModel
    let name: String
    let shortcut: String?
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { frame = proxy.frame(in: .named(Self.space)) }
                        .onChange(of: proxy.frame(in: .named(Self.space))) { _, new in frame = new }
                }
            }
            .onHover { hovering in
                model.hoverRail(RailTip(name: name, shortcut: shortcut, frame: frame), hovering: hovering)
            }
    }
}

private extension View {
    func railHover(_ model: IronPetWindowModel, name: String, shortcut: String?) -> some View {
        modifier(RailHover(model: model, name: name, shortcut: shortcut))
    }
}

/// The small rounded label beside a collapsed rail icon: the name, then its shortcut.
struct RailLabel: View {
    let tip: RailTip

    var body: some View {
        HStack(spacing: 8) {
            Text(tip.name).font(.system(size: 13, weight: .medium))
            if let shortcut = tip.shortcut {
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

/// The sidebar's draggable edge. An AppKit view, not a SwiftUI gesture: the window moves when dragged by its background,
/// and this view says a press on it must not.
struct SidebarResizeHandle: NSViewRepresentable {
    var onBegin: () -> Void
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onBegin: () -> Void = {}
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        private var startX: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            onBegin()
        }

        override func mouseDragged(with event: NSEvent) { onDrag(event.locationInWindow.x - startX) }
        override func mouseUp(with event: NSEvent) { onEnd() }
    }
}

private extension View {
    /// Dragging reorders the built-in rows. A dashboard's icon does not move.
    @ViewBuilder func railReorder(_ row: SidebarRow, model: IronPetWindowModel, available: [IronPetSection], dragged: Binding<IronPetSection?>) -> some View {
        if row.dashboardID == nil {
            onDrag {
                dragged.wrappedValue = row.section
                return NSItemProvider(object: row.section.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: RailDrop(target: row.section, model: model, available: available, dragged: dragged))
        } else {
            self
        }
    }
}

/// The window moves when dragged by its background, which would take a press on a rail icon before `.onDrag` sees it.
/// While the pointer is over the icon, the window stops being movable by its background.
private struct BlocksWindowDrag: ViewModifier {
    @State private var window = WindowBox()

    func body(content: Content) -> some View {
        content
            .background(WindowReader(box: window))
            .onHover { hovering in window.window?.isMovableByWindowBackground = !hovering }
            .onDisappear { window.window?.isMovableByWindowBackground = true }
    }
}

private final class WindowBox { weak var window: NSWindow? }

private struct WindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { box.window = view.window }
    }
}

private extension View {
    func blocksWindowDrag() -> some View { modifier(BlocksWindowDrag()) }
}
