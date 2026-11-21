import AppKit
import SwiftUI
import XCTest
@testable import IronPet
@testable import IronPetCore

@MainActor
final class ListScreenTests: XCTestCase {
    // MARK: Search (S3)

    func testSearchIgnoresCaseAndLooksAtTheTitleAndTheDescription() {
        XCTAssertTrue(ListSearch.matches("ci", in: ["CI failed", nil]))
        XCTAssertTrue(ListSearch.matches("MAIN", in: ["Build", "on the main branch"]))
        XCTAssertFalse(ListSearch.matches("deploy", in: ["Build", "on the main branch"]))
        XCTAssertTrue(ListSearch.matches("cafe", in: ["Café"]), "accents do not matter")
    }

    func testAnEmptyOrBlankSearchMatchesEverything() {
        XCTAssertTrue(ListSearch.matches("", in: ["x"]))
        XCTAssertTrue(ListSearch.matches("   ", in: [nil]))
    }

    func testClearingTheSearchRestoresTheList() {
        let items = ["alpha", "beta", "gamma"]
        XCTAssertEqual(ListSearch.filter(items, query: "AL", title: { $0 }, description: { _ in nil }), ["alpha"])
        XCTAssertEqual(ListSearch.filter(items, query: "", title: { $0 }, description: { _ in nil }), items)
    }

    func testAgentsMatchOnTheProjectAndThePrompt() {
        var a = AgentSession(id: "a", source: .claude, status: .running)
        a.origin.workspace = "/Users/me/ironpet"
        a.prompt = "Fix the flaky login test"
        var b = AgentSession(id: "b", source: .cursor, status: .done)
        b.origin.workspace = "/Users/me/website"
        b.prompt = "Update the footer"
        XCTAssertEqual(AgentsSearch.filter([a, b], query: "IRONPET").map(\.id), ["a"])
        XCTAssertEqual(AgentsSearch.filter([a, b], query: "footer").map(\.id), ["b"])
        XCTAssertEqual(AgentsSearch.filter([a, b], query: "").map(\.id), ["a", "b"])
        XCTAssertTrue(AgentsSearch.filter([a, b], query: "nothing like it").isEmpty)
    }

    func testAlertsMatchOnTheTitleAndTheSubtitle() {
        let ci = Signal(id: "1", title: "CI failed", subtitle: "ironpet #12", url: nil, date: Date(), label: "CI", symbol: "xmark", mood: .failed)
        let pr = Signal(id: "2", title: "Review requested", subtitle: "website #3", url: nil, date: Date(), label: "PR", symbol: "eye", mood: .needsInput)
        XCTAssertEqual(AlertsSearch.filter([ci, pr], query: "ci f").map(\.id), ["1"])
        XCTAssertEqual(AlertsSearch.filter([ci, pr], query: "WEBSITE").map(\.id), ["2"])
    }

    func testNotificationsMatchOnTheTitleAndTheSummary() {
        func item(_ id: String, _ title: String, _ summary: String) -> NotificationItem {
            NotificationItem(id: id, created: Date(), source: "mail", type: .reminder, title: title, summary: summary,
                             description: "", read: nil, links: [])
        }
        let items = [item("1", "Standup", "at ten"), item("2", "Invoice", "from Acme")]
        XCTAssertEqual(NotificationsModel.filter(items, query: "acme").map(\.id), ["2"])
        XCTAssertEqual(NotificationsModel.filter(items, query: "STAND").map(\.id), ["1"])
    }

    func testTasksCombineTheLabelFilterAndTheSearch() {
        let now = Date()
        func task(_ id: String, _ title: String, notes: String, labels: [String: String]) -> TaskItem {
            TaskItem(id: id, title: title, notes: notes, status: .backlog, source: .chat, due: nil, links: [],
                     created: now, updated: now, closed: nil, labels: labels)
        }
        let a = task("a", "Ship the release", notes: "tag it", labels: ["merge": "auto"])
        let b = task("b", "Write docs", notes: "release notes", labels: [:])
        XCTAssertTrue(TaskListView.matches(a, label: nil, query: ""))
        XCTAssertTrue(TaskListView.matches(a, label: "merge=auto", query: "RELEASE"))
        XCTAssertFalse(TaskListView.matches(b, label: "merge=auto", query: "release"), "the search matches, the label does not")
        XCTAssertTrue(TaskListView.matches(b, label: nil, query: "release"), "notes count as the description")
        XCTAssertFalse(TaskListView.matches(a, label: "merge=auto", query: "docs"), "the label matches, the search does not")
    }

    func testTodayDropsSectionsThatHaveNoMatchingItem() {
        let items = [Brief.Item(id: "1", symbol: "checklist", title: "Pay rent", subtitle: nil, target: .task("1")),
                     Brief.Item(id: "2", symbol: "bell", title: "CI failed", subtitle: "ironpet", target: .alert(id: "2", url: nil))]
        let sections = [Brief.Section(id: "s1", title: "Tasks", items: [items[0]]), Brief.Section(id: "s2", title: "Alerts", items: [items[1]])]
        XCTAssertEqual(TodayView.filter(sections, query: "ironpet").map(\.id), ["s2"])
        XCTAssertEqual(TodayView.filter(sections, query: "").map(\.id), ["s1", "s2"])
    }

    // MARK: Navigation (S4)

    func testOpeningARowAndGoingBackKeepsTheSearchAndTheFilter() {
        struct ListState { var search = ""; var label: String?; var nav = ListNavigation<String>() }
        var state = ListState(search: "release", label: "merge=auto")
        state.nav.open("a")
        XCTAssertEqual(state.nav.opened, "a")
        state.nav.close()
        XCTAssertNil(state.nav.opened)
        XCTAssertEqual(state.search, "release")
        XCTAssertEqual(state.label, "merge=auto")
    }

    func testNotificationsOpenInFullAndBackReturnsToTheList() throws {
        let store = NotificationStore(database: try Database(path: nil, migrations: AppMigrations.all))
        let item = try XCTUnwrap(store.add(NotificationDraft(source: "mail", type: .reminder, title: "Hi", description: "Body", links: [])))
        let model = NotificationsModel(api: NotificationsAPI(store: store))
        model.type = .reminder
        model.select(item.id)
        XCTAssertEqual(model.expanded, item.id)
        model.close()
        XCTAssertNil(model.expanded)
        XCTAssertEqual(model.type, .reminder, "the filter survives")
    }

    // MARK: Layout (S1)

    func testTheListWidthIsTheChatColumnWidth() {
        XCTAssertEqual(ListScreenMetrics.maxWidth, ChatView.columnWidth)
    }

    /// Lays `view` out in a 1600 pt wide host and returns where its list column landed.
    private func columnFrame(of view: some View, width: CGFloat = 1600) -> CGRect? {
        var frame: CGRect?
        let host = NSHostingView(rootView: view.frame(width: width, height: 800).onPreferenceChange(ListColumnFrame.self) { frame = $0 })
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return frame
    }

    private func assertCentered(_ frame: CGRect?, in width: CGFloat = 1600, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(frame, "\(name) did not use the list column", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.width, ListScreenMetrics.maxWidth + 0.5, "\(name) is wider than the shared maximum", file: file, line: line)
        XCTAssertEqual(frame.midX, width / 2, accuracy: 1, "\(name) is not centered", file: file, line: line)
    }

    func testListSectionsAreCenteredAtTheSharedWidthInAWideWindow() throws {
        try CISkip.unlessLocal()
        let sessions = SessionStore()
        sessions.loadPreview([AgentSession(id: "1", source: .claude, status: .running)])
        let signals = SignalStore()
        signals.add(Signal(id: "1", title: "CI failed", subtitle: "x", url: nil, date: Date(), label: "CI", symbol: "xmark", mood: .failed), notify: false)
        let notifications = NotificationStore(database: try Database(path: nil, migrations: AppMigrations.all))
        _ = notifications.add(NotificationDraft(source: "mail", type: .reminder, title: "Hi", description: "", links: []))

        try assertCentered(columnFrame(of: AgentsSection(agents: AgentsAPI(store: sessions))), "Agents")
        try assertCentered(columnFrame(of: AlertsSection(alerts: AlertsAPI(store: signals), onAsk: { _ in })), "Alerts")
        try assertCentered(columnFrame(of: ActionsSection(onTrick: { _ in })), "Actions")
        try assertCentered(columnFrame(of: NotificationsSection(model: NotificationsModel(api: NotificationsAPI(store: notifications)),
                                                                focus: .constant(nil))), "Notifications")
    }

    // MARK: Adoption (S1, S2)

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IronPet")
    }

    /// The file that defines each section's view. A new list section goes here, and fails until it builds on `ListScreen`.
    private static let sectionFiles: [IronPetSection: String] = [
        .agents: "Pet/WindowSections.swift", .alerts: "Pet/WindowSections.swift",
        .notifications: "Notifications/NotificationsSection.swift", .tasks: "Pet/TaskListView.swift",
        .transcripts: "Meeting/TranscriptsView.swift", .screen: "Capture/ScreenSection.swift", .actions: "Pet/WindowSections.swift",
        .automations: "App/AutomationsSettings.swift", .today: "Pet/TodayView.swift",
    ]

    func testEveryListSectionIsBuiltWithTheSharedScreen() throws {
        for section in IronPetSection.allCases where section != .chat {
            let file = try XCTUnwrap(Self.sectionFiles[section], "\(section) has no entry; add the file that defines it")
            let text = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("ListScreen(title: IronPetSection.\(section.rawValue).title"), "\(file) does not build \(section) with ListScreen")
        }
    }

    func testNoSectionSetsItsOwnHeaderOrKeepsAFilterBarInTheBody() throws {
        for (section, file) in Self.sectionFiles {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains(".pageHeader(IronPetSection.\(section.rawValue).title"), "\(file) still draws its own header for \(section)")
        }
        let window = try String(contentsOf: Self.sources.appendingPathComponent("Pet/IronPetWindow.swift"), encoding: .utf8)
        XCTAssertFalse(window.contains(".pageHeader(IronPetSection."), "the window wraps a section in its own header")
        let tasks = try String(contentsOf: Self.sources.appendingPathComponent("Pet/TaskListView.swift"), encoding: .utf8)
        XCTAssertFalse(tasks.contains("labelFilterBar"), "the label filter is back in the body")
    }
}
