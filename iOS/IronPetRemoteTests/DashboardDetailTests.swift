import SwiftUI
import XCTest
import IronPetKit
@testable import IronPetRemote

/// An open dashboard keeps its model, and so its content, when the rest of the app changes.
@MainActor
final class DashboardDetailTests: XCTestCase {
    var server: MockIronPetServer!
    var client: IronPetClient!
    var events: SharedEventSource!

    private let dashboard = RemoteDashboard(id: "d-1", title: "Build", icon: "hammer")

    private func page(_ text: String) -> RemoteDashboardView {
        RemoteDashboardView(dashboard: dashboard, root: DashboardNode(type: "text", text: text))
    }

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
        server.dashboardViews = ["d-1": page("first")]
        client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
    }

    override func tearDown() { server.stop() }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func viewRequests() -> Int { server.requests.filter { $0.path == "/v1/dashboards/d-1/view" }.count }

    /// Stands in for `MoreView`: it builds the detail again whenever `tick` changes, as a badge change does.
    @Observable @MainActor final class Parent { var tick = 0 }

    private struct Host: View {
        let parent: Parent
        let list: DashboardsModel
        let make: (String) -> DashboardViewModel
        var body: some View {
            let _ = parent.tick
            NavigationStack { DashboardDetailView(list: list, id: "d-1", makeModel: make) }
        }
    }

    private func open() -> (parent: Parent, models: () -> [DashboardViewModel], window: UIWindow) {
        let list = DashboardsModel(client: client, events: events, onUnauthorized: {})
        let parent = Parent()
        var made: [DashboardViewModel] = []
        let make: (String) -> DashboardViewModel = { id in
            let model = DashboardViewModel(id: id, client: self.client, events: self.events, onUnauthorized: {})
            made.append(model)
            return model
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Host(parent: parent, list: list, make: make))
        window.makeKeyAndVisible()
        return (parent, { made }, window)
    }

    func testAChangeElsewhereKeepsTheOpenDashboardsModelAndContent() async {
        let (parent, models, window) = open()
        defer { window.isHidden = true }
        await poll { models().first?.view != nil }
        let first = models().first
        XCTAssertEqual(first?.view?.root?.text, "first")
        try? await Task.sleep(nanoseconds: 400_000_000) // the socket connects and settles
        let baseline = viewRequests()

        for _ in 0..<3 { parent.tick += 1; try? await Task.sleep(nanoseconds: 50_000_000) }
        server.publish(RemoteEvent.alertsChanged)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(first?.view?.root?.text, "first", "the first model still has the content")
        XCTAssertEqual(viewRequests(), baseline, "a change elsewhere reads nothing more from the Mac")
        XCTAssertGreaterThan(models().count, 1, "the re-renders built more models, and only the first is kept")
    }

    func testAChangeOnTheMacShowsNewContentWithoutEmptyingTheView() async {
        let (_, models, window) = open()
        defer { window.isHidden = true }
        await poll { models().first?.view != nil }
        let model = models().first
        try? await Task.sleep(nanoseconds: 400_000_000)
        let baseline = viewRequests()
        var emptied = false
        server.dashboardViews = ["d-1": page("second")]
        server.publish(RemoteEvent.dashboardsChanged, id: "d-1")
        await poll(10) { emptied = emptied || model?.view == nil; return model?.view?.root?.text == "second" }
        XCTAssertEqual(model?.view?.root?.text, "second")
        XCTAssertFalse(emptied, "the old content stays until the new content replaces it")
        XCTAssertEqual(viewRequests(), baseline + 1, "one read for the change")
    }

    func testClosingStopsTheSubscriptionAndReopeningReadsOnce() async {
        let (_, models, window) = open()
        await poll { models().first?.view != nil }
        try? await Task.sleep(nanoseconds: 400_000_000)
        window.rootViewController = nil // the screen goes away, so `onDisappear` stops the model
        window.isHidden = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        let closed = viewRequests()
        server.dashboardViews = ["d-1": page("changed")]
        server.publish(RemoteEvent.dashboardsChanged, id: "d-1")
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(viewRequests(), closed, "a closed dashboard no longer listens to the Mac")

        let (_, again, second) = open()
        defer { second.isHidden = true }
        await poll { again().first?.view?.root?.text == "changed" }
        XCTAssertEqual(again().first?.view?.root?.text, "changed", "the reopened dashboard loads")
        XCTAssertLessThanOrEqual(viewRequests() - closed, 2, "a reopen reads like a first open: the load, and at most the one on socket connect")
    }

    func testClosingAndOpeningAgainLoads() async {
        let (_, models, window) = open()
        await poll { models().first?.view != nil }
        window.isHidden = true
        let (_, again, second) = open()
        defer { second.isHidden = true }
        await poll { again().first?.view != nil }
        XCTAssertEqual(again().first?.view?.root?.text, "first")
    }
}
