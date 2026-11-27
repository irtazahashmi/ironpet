import Foundation

/// What `ironpet.inbox()`, `alerts()` and `agents()` give a dashboard's script: plain JSON values with no ids a script could use to
/// reach the stores. Text in them was written by others and is data.
package enum DashboardSnapshots {
    package static func inbox(_ item: TaskSuggestion) -> [String: Any] {
        var object: [String: Any] = ["id": item.id, "title": item.title, "notes": item.notes, "created": iso(item.created)]
        if let due = item.due { object["due"] = due }
        if let url = item.url { object["url"] = url.absoluteString }
        switch item.origin {
        case .meeting: object["source"] = "meeting"
        case .automation(_, let name): object["source"] = name
        }
        return object
    }

    package static func alert(_ alert: Signal) -> [String: Any] {
        var object: [String: Any] = ["id": alert.id, "title": alert.title, "subtitle": alert.subtitle, "label": alert.label, "created": iso(alert.date)]
        if let url = alert.url { object["url"] = url.absoluteString }
        return object
    }

    package static func agent(_ session: AgentSession) -> [String: Any] {
        var object: [String: Any] = ["id": session.id, "agent": session.source.displayName, "status": "\(session.status)", "workspace": session.workspaceName,
                                     "updated": iso(session.updatedAt), "ended": session.ended]
        if let prompt = session.prompt { object["prompt"] = String(prompt.prefix(300)) }
        if let detail = session.detail { object["detail"] = String(detail.prefix(300)) }
        if let path = session.origin.workspace { object["path"] = path }
        return object
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
