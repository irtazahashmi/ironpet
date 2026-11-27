import Foundation

/// The dashboard calls. The Mac runs each dashboard's script, so the phone reads a finished view and reports taps by handler id.
extension IronPetClient {
    public func dashboards() async throws -> [RemoteDashboard] { try await get(DashboardListResponse.self, APIPath.dashboards).dashboards }

    public func dashboardView(id: String) async throws -> RemoteDashboardView { try await get(RemoteDashboardView.self, APIPath.dashboardView(id)) }

    /// Runs the handler a tapped element named. The Mac sends a prompt and changes the data itself. The answer lists what the phone should do.
    public func dashboardClick(id: String, handler: String) async throws -> RemoteDashboardClick {
        try await post(RemoteDashboardClick.self, APIPath.dashboardClick(id), json: ["handler": handler])
    }

    /// Changes the icon, the colour or both. It is the only change a phone may make to a dashboard.
    public func setDashboardAppearance(id: String, icon: String? = nil, color: String? = nil) async throws -> RemoteDashboard {
        var change: [String: Any] = [:]
        if let icon { change["icon"] = icon }
        if let color { change["color"] = color }
        let data = try JSONSerialization.data(withJSONObject: change)
        return try decode(RemoteDashboard.self, from: try await perform(request("PATCH", APIPath.dashboard(id), body: data)))
    }
}
