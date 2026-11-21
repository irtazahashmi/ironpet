import Foundation

/// What the user has to approve before an agent acts, whatever the app. The words are generic verbs, never the names of apps or of
/// their buttons: a button called "Send" in any app asks, and no app is trusted to skip the question.
package enum DesktopSafety {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(send|sends|sending|pay|pays|paying|payment|delete|deletes|deleting|submit|submits|submitting|buy|buys|buying|purchase|purchases|check ?out|transfer|transfers)\b"#,
        options: .caseInsensitive)

    /// The verb that makes `text` need approval, or nil.
    package static func riskyVerb(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range), let found = Range(match.range, in: text) else { return nil }
        return text[found].lowercased()
    }

    /// Why an action needs the user's approval, or nil when it does not. `element` is what the element shows (its name, and its value
    /// unless the user types into it); `window` is the window title.
    package static func approvalReason(element: [String], window: String?) -> String? {
        for text in element { if let verb = riskyVerb(in: text) { return "the element says \"\(verb)\"" } }
        if let window, let verb = riskyVerb(in: window) { return "the window title says \"\(verb)\"" }
        return nil
    }
}

extension DesktopSafety {
    /// Key codes of q and w, which with Command quit the app or close the window.
    private static let quitCode: UInt16 = 12, closeCode: UInt16 = 13

    /// Why a key press needs the user's approval, or nil. Cmd+Return, and Cmd with q or w, always ask: they send, quit or close in
    /// most apps. Any other press that holds Command or is Return asks when the focused window or element says send, pay, delete,
    /// submit or buy. A plain letter, Tab, Escape or an arrow never asks. `element` is what the focused element shows.
    package static func keyApprovalReason(_ stroke: DesktopKeyStroke, element: [String], window: String?) -> String? {
        if stroke.hasCommand {
            if stroke.isReturn { return "Cmd+Return sends or submits in most apps" }
            if stroke.keyCode == quitCode { return "Cmd+Q quits the app" }
            if stroke.keyCode == closeCode { return "Cmd+W closes the window" }
        }
        guard stroke.hasCommand || stroke.isReturn else { return nil }
        return approvalReason(element: element, window: window).map { "\($0) and the key can trigger it" }
    }
}

/// What the user was asked about an action.
package struct DesktopApproval: Equatable {
    package init(id: UUID = UUID(), title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }

    package var id = UUID()
    package var title: String
    package var detail: String
}

/// One action an agent took or tried, as the log keeps it.
package struct DesktopActionRecord: Equatable {
    package init(at: Date, app: String, window: String, role: String, name: String, action: String, outcome: Outcome, note: String = "") {
        self.at = at
        self.app = app
        self.window = window
        self.role = role
        self.name = name
        self.action = action
        self.outcome = outcome
        self.note = note
    }

    package enum Outcome: String { case done, failed, declined, refused }

    package var at: Date
    package var app: String
    package var window: String
    package var role: String
    package var name: String
    package var action: String
    package var outcome: Outcome
    /// Why it failed, was refused or needed approval.
    package var note: String = ""
}

extension ActivityEvent.Kind {
    package static let desktopAction = ActivityEvent.Kind("desktop.action")
}

extension ActivityEvent {
    package enum DesktopKey {
        package static let app = "app", window = "window", role = "role", name = "name", action = "action", outcome = "outcome", note = "note"
    }

    /// One desktop action an agent took. The element's name is cut like any other activity text.
    package static func desktopAction(_ record: DesktopActionRecord) -> ActivityEvent {
        let name = record.name.isEmpty ? record.role : "\(record.role) \"\(clamp(record.name, 60))\""
        let target = name.isEmpty ? "" : " \(name)"
        return ActivityEvent(at: record.at, kind: .desktopAction, ref: record.app, title: "\(record.action)\(target) in \(record.app)",
                             detail: record.note,
                             extra: [DesktopKey.app: record.app, DesktopKey.window: clamp(record.window, 80), DesktopKey.role: record.role,
                                     DesktopKey.name: clamp(record.name, 80), DesktopKey.action: record.action,
                                     DesktopKey.outcome: record.outcome.rawValue, DesktopKey.note: clamp(record.note, 120)])
    }
}

/// Asks the user through a bubble and waits for the answer. No answer within `timeout` is a no.
@MainActor
package final class DesktopApprovals {
    private let present: (DesktopApproval, @escaping (Bool) -> Void) -> Void
    private let dismiss: (DesktopApproval) -> Void
    private let timeout: TimeInterval

    package init(timeout: TimeInterval = 120, present: @escaping (DesktopApproval, @escaping (Bool) -> Void) -> Void, dismiss: @escaping (DesktopApproval) -> Void) {
        self.timeout = timeout
        self.present = present
        self.dismiss = dismiss
    }

    package func ask(_ request: DesktopApproval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var answered = false
            let finish: (Bool) -> Void = { [dismiss] answer in
                guard !answered else { return }
                answered = true
                if !answer { dismiss(request) }
                continuation.resume(returning: answer)
            }
            present(request, finish)
            Task { @MainActor [timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(false)
            }
        }
    }
}
