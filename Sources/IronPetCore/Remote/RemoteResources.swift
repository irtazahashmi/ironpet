import Foundation
import IronPetKit

/// The pet, bubbles, agents, alerts, today and asset routes, as calls on `IronPetAPI`. Like `RemoteTasks` they answer with the
/// `IronPetKit` types the phone decodes, and they never reach into a store: everything goes through the API namespaces.
@MainActor
package struct RemoteResources {
    package init(api: IronPetAPI, device: String) {
        self.api = api
        self.device = device
    }

    package let api: IronPetAPI
    /// The device that calls. Its id names the origin of a chat message.
    package let device: String

    // MARK: Pet

    package func pet() async -> [String: Any] {
        let state = api.pet.state()
        let assets = await api.pet.manifest().assets
        let config = api.settings.config
        let accent = api.pet.accent()
        return RemoteWire.object(RemotePet(name: config.pet.name, mood: state.mood, badge: state.badge, tricks: api.pet.tricks(),
                                           background: config.chat.background, sprite: assets.contains { $0.id == "pet.sprite" } ? "pet.sprite" : nil,
                                           backgroundAsset: assets.contains { $0.id == "chat.background" } ? "chat.background" : nil,
                                           accent: accent?.light, accentDark: accent?.dark))
    }

    package func trick(_ name: String) throws -> [String: Any] {
        try api.pet.perform(PerformTrickRequest(name: name))
        return RemoteWire.object(RemoteTrickResult(performed: name))
    }

    // MARK: Bubbles

    /// A bubble with a Mac-only decision keeps its text but loses its buttons, and says so, so the phone shows "Answer on the Mac".
    package func bubbles() -> [String: Any] {
        RemoteWire.object(BubbleListResponse(bubbles: api.bubbles.list().map { bubble in
            RemoteBubble(id: bubble.id, symbol: bubble.symbol, title: bubble.title, subtitle: bubble.subtitle, body: bubble.body,
                         lines: bubble.lines.map(\.text),
                         actions: bubble.macOnly ? [] : bubble.actions.map { RemoteBubbleAction(id: $0.id, title: $0.title, style: $0.style) },
                         macOnly: bubble.macOnly, expires: bubble.expires)
        }))
    }

    /// Presses a button. The action id is the one `bubbles()` listed, so an id that is unknown, belongs to a bubble that is gone or to a
    /// Mac-only bubble is a 404. Pressing runs the button's closure once and closes the bubble, as a click on the Mac does.
    package func press(bubble: String, action: String) throws -> [String: Any] {
        guard let info = api.bubbles.list().first(where: { $0.id == bubble }), !info.macOnly else {
            throw RemoteFailure(status: 404, code: "not_found", message: "no bubble with id \"\(bubble)\"")
        }
        try api.bubbles.press(PressBubbleRequest(bubble: bubble, action: action, line: nil))
        return RemoteWire.object(RemoteBubblePress(pressed: action))
    }

    // MARK: Agents

    private func dto(_ session: AgentSession, detail: Bool) -> RemoteAgent {
        RemoteAgent(id: session.id, source: session.source.rawValue, sourceName: session.source.displayName, status: Self.name(session.status),
                    statusLabel: session.status.label, workspace: session.workspaceName, prompt: session.prompt, detail: session.detail,
                    summary: session.summary, editedFiles: session.editedFiles, updated: session.updatedAt,
                    lastResponse: detail ? session.lastResponse : nil)
    }

    private static func name(_ status: AgentStatus) -> AgentStatusName {
        switch status {
        case .idle: return .idle
        case .running: return .running
        case .done: return .done
        case .failed: return .failed
        case .needsInput: return .needsInput
        }
    }

    /// Sessions that are not idle, the ones that need the user first.
    package func agents() -> [String: Any] { RemoteWire.object(AgentListResponse(agents: api.agents.list().map { dto($0, detail: false) })) }

    package func agent(_ id: String) throws -> [String: Any] { RemoteWire.object(dto(try api.agents.get(id), detail: true)) }

    package func acknowledge(_ id: String) throws -> [String: Any] {
        try api.agents.acknowledge(id)
        return RemoteWire.object(RemoteAcknowledged(acknowledged: id))
    }

    package func askAboutAgent(_ id: String) async throws -> [String: Any] {
        let session = try api.agents.get(id)
        var text = AgentsAPI.prompt(for: session)
        if let summary = session.summary { text += " Its summary: \(summary)" }
        return try await ask(text)
    }

    /// One chat message from this device. It goes into the chat that is open, like any other client's, and is not read aloud.
    private func ask(_ text: String) async throws -> [String: Any] {
        let result = try await api.chat.send(SendChatRequest(text: text, origin: ChatOrigin(client: "ios", ref: device)))
        return RemoteWire.object(RemoteSendResult(outcome: result.outcome.rawValue))
    }

    // MARK: Alerts

    package func alerts() -> [String: Any] {
        RemoteWire.object(AlertListResponse(alerts: api.alerts.list().map { alert in
            RemoteAlert(id: alert.id, title: alert.title, subtitle: alert.subtitle, label: alert.label, symbol: alert.symbol, mood: alert.mood.rawValue,
                        date: alert.date, canAsk: alert.ask != nil, url: alert.url?.absoluteString, detail: alert.detail)
        }))
    }

    package func dismissAlert(_ id: String) throws -> [String: Any] {
        try api.alerts.dismiss(id)
        return RemoteWire.object(RemoteDismissed(dismissed: id))
    }

    package func dismissAllAlerts() -> [String: Any] {
        let count = api.alerts.list().count
        api.alerts.dismissAll()
        return RemoteWire.object(RemoteDismissedCount(dismissed: count))
    }

    package func askAboutAlert(_ id: String) async throws -> [String: Any] {
        guard let prompt = try api.alerts.get(id).ask else { throw RemoteFailure.invalid("this alert has nothing to ask about") }
        return try await ask(prompt)
    }

    // MARK: Today

    package func today(kind: String?) throws -> [String: Any] {
        guard let kind = Brief.Kind(rawValue: kind ?? "brief") else { throw RemoteFailure.invalid("kind must be brief or recap") }
        let brief = api.today.brief(BriefRequest(kind: kind))
        return RemoteWire.object(RemoteToday(kind: kind.rawValue, title: kind.title, lines: brief.lines, sections: brief.sections.map { section in
            TodaySection(id: section.id, title: section.title, items: section.items.map {
                TodayItem(id: $0.id, symbol: $0.symbol, title: $0.title, subtitle: $0.subtitle, target: Self.target($0.target))
            })
        }))
    }

    /// What a Today item opens, with the alert's `url` when it has one. The app maps the type to a tab.
    package static func target(_ target: Brief.Target) -> TodayTarget {
        switch target {
        case .task(let id): return TodayTarget(type: .task, id: id)
        case .session(let id, _, _, _): return TodayTarget(type: .session, id: id)
        case .alert(let id, let url): return TodayTarget(type: .alert, id: id, url: url?.absoluteString)
        case .meeting(let id): return TodayTarget(type: .meeting, id: id)
        }
    }

    // MARK: Assets

    /// What a phone may download, by content hash. Sprite sheets and the custom chat background hold no personal data.
    package func manifest() async -> [String: Any] {
        RemoteWire.object(AssetManifestResponse(assets: await api.pet.manifest().assets.map { entry in
            RemoteAsset(id: entry.id, kind: entry.kind == .sprite ? "spritesheet" : "image", name: entry.name, sha256: entry.sha256, bytes: entry.bytes,
                        contentType: Self.contentType(entry.name), width: entry.width, height: entry.height)
        }))
    }

    package func asset(sha256: String) async throws -> (data: Data, contentType: String) {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { throw RemoteFailure(status: 404, code: "not_found", message: "no asset with this hash") }
        let found = try await api.pet.assetData(sha256: sha256.lowercased())
        return (found.data, Self.contentType(found.entry.name))
    }

    package static func contentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }
}
