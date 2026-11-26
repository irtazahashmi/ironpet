import Foundation

/// One thing ironpet saw happen or told the user about, as stored in `activity_events`: an agent turn that finished, an
/// alert that opened or that its watcher cleared, a bubble from an automation. The welcome back summary and the daily
/// brief read these back for a time window, so they can say what happened while nobody was looking or after a restart.
package struct ActivityEvent: Equatable {
    /// Open-ended on purpose: a feature can record its own kind (`task.handoff.done`) without changing this file, and
    /// readers ignore kinds they do not know.
    package struct Kind: RawRepresentable, Hashable, Comparable {
        package let rawValue: String
        package init(rawValue: String) { self.rawValue = rawValue }
        package init(_ rawValue: String) { self.rawValue = rawValue }

        package static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        package static let sessionNeedsInput = Kind("session.needsInput")
        package static let sessionFailed = Kind("session.failed")
        package static let sessionDone = Kind("session.done")
        package static let alertOpened = Kind("alert.opened")
        /// Cleared by the automation that raised it, not dismissed by the user.
        package static let alertResolved = Kind("alert.resolved")
        package static let automationBubble = Kind("automation.bubble")
        package static let taskSuggested = Kind("task.suggested")
        package static let meetingSummary = Kind("meeting.summary")
        package static let chatFinished = Kind("chat.finished")

        package var isSession: Bool { rawValue.hasPrefix("session.") }
    }

    package static let detailLimit = 300
    package static let summaryLimit = 140

    package var at: Date
    package var kind: Kind
    /// What the event is about, so readers can fold repeats: a session id, an alert id, a task id, a file path.
    package var ref: String
    package var title: String
    package var detail: String
    package var url: URL?
    /// Small string facts a reader may need later, such as how to reopen a session that has ended.
    package var extra: [String: String]

    package init(at: Date = Date(), kind: Kind, ref: String, title: String, detail: String = "", url: URL? = nil, extra: [String: String] = [:]) {
        self.at = at
        self.kind = kind
        self.ref = ref
        self.title = title
        self.detail = Self.clamp(detail, Self.detailLimit)
        self.url = url
        self.extra = extra
    }

    package static func clamp(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

// MARK: From what the app announces

extension ActivityEvent {
    /// Extra keys for a session, enough to jump to it after the session store has forgotten it.
    package enum SessionKey {
        package static let workspace = "workspace", agent = "agent", app = "app", iterm = "iterm"
    }

    /// An agent session that started needing input, failed or finished. Nil for any other status.
    package static func session(_ session: AgentSession, at: Date = Date()) -> ActivityEvent? {
        let kind: Kind
        switch session.status {
        case .needsInput: kind = .sessionNeedsInput
        case .failed: kind = .sessionFailed
        case .done: kind = .sessionDone
        default: return nil
        }
        var extra = [SessionKey.agent: session.source.rawValue]
        extra[SessionKey.workspace] = session.origin.workspace
        extra[SessionKey.app] = session.origin.ownerBundleID
        extra[SessionKey.iterm] = session.isInIterm ? session.origin.itermSessionID : nil
        // Never the user's prompt: only the agent's summary line, or the request it is waiting on, is kept for 30 days.
        let detail = session.status == .needsInput ? session.detail : session.summary
        return ActivityEvent(at: at, kind: kind, ref: session.id, title: session.workspaceName,
                             detail: clamp(detail ?? "", summaryLimit), extra: extra)
    }

    package enum AlertKey {
        package static let label = "label", mood = "mood", symbol = "symbol"
    }

    /// An alert the user was told about: new, or changed since it was last shown.
    package static func alertOpened(_ signal: Signal, at: Date = Date()) -> ActivityEvent {
        alert(signal, kind: .alertOpened, at: at)
    }

    /// An alert its automation cleared. Read the signal before it leaves the store, since the row has the title and url.
    package static func alertResolved(_ signal: Signal, at: Date = Date()) -> ActivityEvent {
        alert(signal, kind: .alertResolved, at: at)
    }

    private static func alert(_ signal: Signal, kind: Kind, at: Date) -> ActivityEvent {
        ActivityEvent(at: at, kind: kind, ref: signal.id, title: signal.title, detail: signal.subtitle, url: signal.url,
                      extra: [AlertKey.label: signal.label, AlertKey.mood: signal.mood.rawValue, AlertKey.symbol: signal.symbol])
    }

    package enum AutomationKey {
        package static let automation = "automation", tint = "tint"
    }

    /// A bubble from a scheduled job, poll or script. Nil for what is not news after a break: break reminders,
    /// questions that wait for an answer (no expiry) and bubbles that belong to no automation.
    package static func automationNotice(_ notice: AutomationNotice, at: Date = Date()) -> ActivityEvent? {
        guard !notice.isBreakReminder, notice.expires != nil, let automation = notice.automationIDs.first else { return nil }
        let tint: String
        switch notice.tint {
        case .info: tint = "info"
        case .good: tint = "good"
        case .bad: tint = "bad"
        case .warn: tint = "warn"
        }
        return ActivityEvent(at: at, kind: .automationBubble, ref: notice.id, title: notice.title,
                             detail: clamp(notice.body ?? notice.subtitle ?? "", 200), url: notice.url,
                             extra: [AutomationKey.automation: automation, AutomationKey.tint: tint])
    }

    package static func taskSuggested(_ suggestion: TaskSuggestion, at: Date = Date()) -> ActivityEvent {
        ActivityEvent(at: at, kind: .taskSuggested, ref: suggestion.id, title: suggestion.title, detail: suggestion.originLabel)
    }

    package static func meetingSummary(_ summary: URL, at: Date = Date()) -> ActivityEvent {
        ActivityEvent(at: at, kind: .meetingSummary, ref: summary.path, title: summary.deletingLastPathComponent().lastPathComponent, url: summary)
    }

    /// A Ghost chat turn that ended while the chat was hidden. `title` is what the bubble said.
    package static func chatFinished(_ title: String, at: Date = Date()) -> ActivityEvent {
        ActivityEvent(at: at, kind: .chatFinished, ref: "chat", title: title)
    }
}
