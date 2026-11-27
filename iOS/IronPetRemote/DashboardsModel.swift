import Foundation
import IronPetKit
import Observation

/// The dashboards the Mac has, for the top of the More tab. The Mac runs each script; this model only lists them and follows
/// `dashboards.changed`, so an icon, a title or a count changed on the Mac shows here without a pull.
@MainActor @Observable
final class DashboardsModel: SocketModel {
    private(set) var dashboards: [RemoteDashboard] = []

    /// What the dashboards add to the More tab's badge: the counts they show.
    var badge: Int { dashboards.compactMap(\.count).reduce(0, +) }

    override func reload() async {
        // A Mac that is older than this phone has no dashboards route. The list is empty for it, not a failed read.
        let list = await read { () async throws -> [RemoteDashboard] in
            do { return try await self.client.dashboards() } catch ClientError.api(_, _, _), ClientError.invalidResponse { return [] }
        }
        guard let list else { return }
        dashboards = list
    }

    override func handle(_ event: RemoteEvent) async {
        if event.kind == RemoteEvent.dashboardsChanged { debouncer.run("dashboards") { [weak self] in await self?.reload() } }
    }

    /// Picks another icon or colour. The Mac applies it and every client follows.
    func setAppearance(_ dashboard: RemoteDashboard, icon: String? = nil, color: String? = nil) async {
        if let updated = await run({ try await self.client.setDashboardAppearance(id: dashboard.id, icon: icon, color: color) }),
           let index = dashboards.firstIndex(where: { $0.id == updated.id }) {
            dashboards[index] = updated
        }
    }
}

/// One dashboard open on the phone: the view the Mac built, and what a tap does.
@MainActor @Observable
final class DashboardViewModel: SocketModel {
    let id: String
    private(set) var view: RemoteDashboardView?
    /// What the last tap said went wrong, in the Mac's words.
    var notice: String?
    /// The chat tab opens when a tap sent the pet a prompt.
    @ObservationIgnored var openChat: () -> Void = {}
    @ObservationIgnored var openLink: (URL) -> Void = { _ in }

    init(id: String, client: IronPetClient, events: any EventSignalSource, network: NetworkHealth? = nil, onUnauthorized: @escaping () -> Void) {
        self.id = id
        super.init(client: client, events: events, network: network, onUnauthorized: onUnauthorized)
    }

    override func reload() async {
        if let current = await read({ try await self.client.dashboardView(id: self.id) }) { view = current }
    }

    override func handle(_ event: RemoteEvent) async {
        // The id is the dashboard that changed. An event with no id reads every dashboard again.
        if event.kind == RemoteEvent.dashboardsChanged, event.id == nil || event.id == id {
            debouncer.run("dashboard-\(id)") { [weak self] in await self?.reload() }
        }
    }

    func tap(_ handler: String) async {
        guard let result = await run({ try await self.client.dashboardClick(id: self.id, handler: handler) }) else { return }
        notice = result.error
        for effect in result.effects {
            switch effect.kind {
            case "chat": openChat()
            case "open": if let text = effect.value, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) { openLink(url) }
            default: break // A file is on the Mac.
            }
        }
        await reload()
    }
}
