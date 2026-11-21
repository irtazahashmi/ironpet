import Foundation

/// The pet, bubbles, agents, alerts, today and asset routes, as calls on `IronPetAPI`. Like `RemoteTasks` they return JSON objects with
/// snake_case keys and ISO 8601 dates, and they never reach into a store: everything goes through the API namespaces.
@MainActor
package struct RemoteResources {
    package init(api: IronPetAPI, device: String) {
        self.api = api
        self.device = device
    }

    package let api: IronPetAPI
    /// The device that calls. Its id names the origin of a chat message.
    package let device: String

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    // MARK: Pet

    package func pet() async -> [String: Any] {
        let state = api.pet.state()
        let assets = await api.pet.manifest().assets
        let config = api.settings.config
        var object: [String: Any] = ["name": config.pet.name, "mood": state.mood, "badge": state.badge, "tricks": api.pet.tricks(),
                                     "background": config.chat.background]
        if assets.contains(where: { $0.id == "pet.sprite" }) { object["sprite"] = "pet.sprite" }
        if assets.contains(where: { $0.id == "chat.background" }) { object["background_asset"] = "chat.background" }
        return object
    }

    package func trick(_ name: String) throws -> [String: Any] {
        try api.pet.perform(PerformTrickRequest(name: name))
        return ["performed": name]
    }

    // MARK: Bubbles

    /// A bubble with a Mac-only decision keeps its text but loses its buttons, and says so, so the phone shows "Answer on the Mac".
    package func bubbles() -> [String: Any] {
        ["bubbles": api.bubbles.list().map { bubble -> [String: Any] in
            var object: [String: Any] = ["id": bubble.id, "symbol": bubble.symbol, "title": bubble.title, "mac_only": bubble.macOnly,
                                         "lines": bubble.lines.map(\.text),
                                         "actions": bubble.macOnly ? [] : bubble.actions.map { ["id": $0.id, "title": $0.title, "style": $0.style] }]
            if let subtitle = bubble.subtitle { object["subtitle"] = subtitle }
            if let body = bubble.body { object["body"] = body }
            if let expires = bubble.expires { object["expires"] = Self.iso(expires) }
            return object
        }]
    }

    /// Presses a button. The action id is the one `bubbles()` listed, so an id that is unknown, belongs to a bubble that is gone or to a
    /// Mac-only bubble is a 404. Pressing runs the button's closure once and closes the bubble, as a click on the Mac does.
    package func press(bubble: String, action: String) throws -> [String: Any] {
        guard let info = api.bubbles.list().first(where: { $0.id == bubble }), !info.macOnly else {
            throw RemoteFailure(status: 404, code: "not_found", message: "no bubble with id \"\(bubble)\"")
        }
        try api.bubbles.press(PressBubbleRequest(bubble: bubble, action: action, line: nil))
        return ["pressed": action]
    }

    // MARK: Agents

    private func json(_ session: AgentSession, detail: Bool) -> [String: Any] {
        var object: [String: Any] = ["id": session.id, "source": session.source.rawValue, "source_name": session.source.displayName,
                                     "status": Self.name(session.status), "status_label": session.status.label,
                                     "workspace": session.workspaceName, "edited_files": session.editedFiles, "updated": Self.iso(session.updatedAt)]
        if let prompt = session.prompt { object["prompt"] = prompt }
        if let text = session.detail { object["detail"] = text }
        if let summary = session.summary { object["summary"] = summary }
        if detail, let reply = session.lastResponse { object["last_response"] = reply }
        return object
    }

    private static func name(_ status: AgentStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        case .needsInput: return "needs_input"
        }
    }

    /// Sessions that are not idle, the ones that need the user first.
    package func agents() -> [String: Any] { ["agents": api.agents.list().map { json($0, detail: false) }] }

    package func agent(_ id: String) throws -> [String: Any] { json(try api.agents.get(id), detail: true) }

    package func acknowledge(_ id: String) throws -> [String: Any] {
        try api.agents.acknowledge(id)
        return ["acknowledged": id]
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
        return ["outcome": result.outcome.rawValue]
    }

    // MARK: Alerts

    package func alerts() -> [String: Any] {
        ["alerts": api.alerts.list().map { alert -> [String: Any] in
            var object: [String: Any] = ["id": alert.id, "title": alert.title, "subtitle": alert.subtitle, "label": alert.label, "symbol": alert.symbol,
                                         "mood": alert.mood.rawValue, "date": Self.iso(alert.date), "can_ask": alert.ask != nil]
            if let url = alert.url { object["url"] = url.absoluteString }
            if let detail = alert.detail { object["detail"] = detail }
            return object
        }]
    }

    package func dismissAlert(_ id: String) throws -> [String: Any] {
        try api.alerts.dismiss(id)
        return ["dismissed": id]
    }

    package func dismissAllAlerts() -> [String: Any] {
        let count = api.alerts.list().count
        api.alerts.dismissAll()
        return ["dismissed": count]
    }

    package func askAboutAlert(_ id: String) async throws -> [String: Any] {
        guard let prompt = try api.alerts.get(id).ask else { throw RemoteFailure.invalid("this alert has nothing to ask about") }
        return try await ask(prompt)
    }

    // MARK: Today

    package func today(kind: String?) throws -> [String: Any] {
        guard let kind = Brief.Kind(rawValue: kind ?? "brief") else { throw RemoteFailure.invalid("kind must be brief or recap") }
        let brief = api.today.brief(BriefRequest(kind: kind))
        return ["kind": kind.rawValue, "title": kind.title, "lines": brief.lines,
                "sections": brief.sections.map { section -> [String: Any] in
                    ["id": section.id, "title": section.title, "items": section.items.map { item -> [String: Any] in
                        var object: [String: Any] = ["id": item.id, "symbol": item.symbol, "title": item.title, "target": Self.target(item.target)]
                        if let subtitle = item.subtitle { object["subtitle"] = subtitle }
                        return object
                    }]
                }]
    }

    /// `{"type": "task" | "session" | "alert" | "meeting", "id": ...}`, with the alert's `url` when it has one. The app maps the type to a tab.
    package static func target(_ target: Brief.Target) -> [String: Any] {
        switch target {
        case .task(let id): return ["type": "task", "id": id]
        case .session(let id, _, _, _): return ["type": "session", "id": id]
        case .alert(let id, let url):
            var object: [String: Any] = ["type": "alert", "id": id]
            if let url { object["url"] = url.absoluteString }
            return object
        case .meeting(let id): return ["type": "meeting", "id": id]
        }
    }

    // MARK: Assets

    /// What a phone may download, by content hash. Sprite sheets and the custom chat background hold no personal data.
    package func manifest() async -> [String: Any] {
        ["assets": await api.pet.manifest().assets.map { entry -> [String: Any] in
            var object: [String: Any] = ["id": entry.id, "kind": entry.kind == .sprite ? "spritesheet" : "image", "name": entry.name,
                                         "sha256": entry.sha256, "bytes": entry.bytes, "content_type": Self.contentType(entry.name)]
            if let width = entry.width { object["width"] = width }
            if let height = entry.height { object["height"] = height }
            return object
        }]
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
