import Foundation
import IronPetKit

/// The dashboard routes, as calls on `IronPetAPI.dashboards`. The Mac runs every script, so a phone gets a finished view and sends
/// back the id of the handler a tap runs. A phone can change a dashboard's icon and colour. It cannot approve capabilities: that
/// stays a decision made on the Mac.
@MainActor
package struct RemoteDashboards {
    package init(api: IronPetAPI) { self.api = api }

    package let api: IronPetAPI

    package func list() -> [String: Any] { ["dashboards": RemoteWire.array(api.dashboards.list())] }

    package func view(_ id: String) async throws -> [String: Any] { RemoteWire.object(try await api.dashboards.view(id)) }

    package func click(_ id: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let handler = body["handler"] as? String, !handler.isEmpty else { throw RemoteFailure.invalid("handler is required") }
        return RemoteWire.object(try await api.dashboards.click(DashboardClickRequest(id: id, handler: handler)))
    }

    package func setAppearance(_ id: String, _ body: [String: Any]) throws -> [String: Any] {
        let icon = body["icon"] as? String, color = body["color"] as? String
        guard icon != nil || color != nil else { throw RemoteFailure.invalid("send icon, color or both") }
        try api.dashboards.setAppearance(id: id, icon: icon, color: color)
        guard let updated = api.dashboards.list().first(where: { $0.id == id }) else { throw APIError.notFound("no dashboard \(id)") }
        return RemoteWire.object(updated)
    }
}
