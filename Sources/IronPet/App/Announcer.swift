import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import SwiftUI

/// Everything ironpet announces goes out as a bubble next to Ghost, and optionally as a macOS notification too.
@MainActor
final class Announcer {
    private static let systemKey = "notifications.system"

    let bubbles = BubbleStore()
    let notifier: Notifier

    /// Opens the address of a bubble's `open-url` action. `AppDelegate` sets the platform's.
    var urlOpener: URLOpener = UnsupportedURLOpener()
    var openSession: (String) -> Void = { _ in }
    var openChat: () -> Void = {}
    var ask: (String) -> Void = { _ in }
    var decide: (UUID, Bool) -> Void = { _, _ in }
    var automationAction: (_ ids: [String], _ snooze: Bool) -> Void = { _, _ in }
    /// Where the bubbles that agents, alerts and digests show are also stored. Automation bubbles are stored by `AutomationService`.
    var notifications: NotificationStore?
    /// Shows the Notifications section with this entry open. A bubble's click ends here.
    var openNotification: (String) -> Void = { _ in }

    /// Stores a notification and returns what a click on its bubble does.
    private func store(_ draft: NotificationDraft) -> (() -> Void)? {
        guard let id = notifications?.add(draft)?.id else { return nil }
        return { [weak self] in self?.openNotification(id) }
    }

    var alsoSystemNotifications: Bool {
        get { UserDefaults.standard.bool(forKey: Self.systemKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.systemKey) }
    }

    init(notifier: Notifier) {
        self.notifier = notifier
        notifier.onOpen = { [weak self] id in self?.openSession(id) }
        notifier.onOpenChat = { [weak self] in self?.openChat() }
        notifier.onApprovalAction = { [weak self] id, allow in self?.decide(id, allow) }
        notifier.onAutomationAction = { [weak self] ids, snooze in self?.automationAction(ids, snooze) }
    }

    func session(_ session: AgentSession) {
        let id = session.id
        let open = BubbleDraft.Button("open", Editors.label(for: session), style: .primary) { [weak self] in
            self?.openSession(id)
        }
        let body = session.status == .needsInput ? (session.detail ?? session.prompt) : (session.summary ?? session.prompt)
        bubbles.show(BubbleDraft(id: "session:\(id)", symbol: session.status.symbol, tint: session.status.bubbleTint,
                            title: "\(session.workspaceName): \(session.status.label)", subtitle: session.source.displayName,
                            body: body, actions: [open], onTap: { [weak self] in self?.openSession(id) },
                            expires: Date().addingTimeInterval(session.status == .done ? 15 : 45)))
        if session.status != .done { chime() }
        if alsoSystemNotifications { notifier.announce(session) }
    }

    /// `agentName` is the agent that asks, when it is not agent 1, so the bubble says who wants what.
    func approval(id: UUID, title: String, detail: String, agentName: String? = nil) {
        let heading = "\(agentName ?? ConfigStore.shared.config.pet.name) wants to: \(title)"
        let open = store(NotificationDraft(type: .approval, title: heading, summary: NotificationDraft.summary(of: detail), description: detail))
        bubbles.show(Self.approvalBubble(id: id, heading: heading, detail: detail, decide: { [weak self] allow in self?.decide(id, allow) },
                                         openChat: { [weak self] in self?.openChat() }, open: open))
        chime()
        if alsoSystemNotifications { notifier.announceApproval(id: id, title: title, detail: detail) }
    }

    /// The Allow and Deny bubble of a chat tool request. Only the Mac answers it.
    static func approvalBubble(id: UUID, heading: String, detail: String, decide: @escaping (Bool) -> Void, openChat: @escaping () -> Void,
                               open: (() -> Void)?) -> BubbleDraft {
        BubbleDraft(id: approvalID(id), symbol: SharedSymbols.approval, tint: .orange, title: heading, body: String(detail.prefix(240)),
               actions: [
                   .init("allow", "Allow", style: .primary) { decide(true) },
                   .init("deny", "Deny", style: .destructive) { decide(false) },
                   .init("open-chat", "Open chat", run: openChat),
               ], onTap: open, macOnly: true)
    }

    /// A job or automation session asked for permission. The bubble has one button per option the agent offered, with the agent's
    /// labels, and a notification goes out whether or not system notifications are on, because the run is waiting.
    func backgroundPermission(_ request: BackgroundPermissions.Request, answer: @escaping (String) -> Void) {
        bubbles.show(Self.backgroundPermissionBubble(request, answer: answer, openChat: { [weak self] in self?.openChat() }))
        chime()
        notifier.announceApproval(id: request.id, title: request.heading, detail: request.detail)
    }

    static func backgroundPermissionBubble(_ request: BackgroundPermissions.Request, answer: @escaping (String) -> Void,
                                           openChat: @escaping () -> Void) -> BubbleDraft {
        let actions = request.options.map { option in
            BubbleDraft.Button("option:\(option.id)", option.name, style: option.allows ? .primary : option.kind.hasPrefix("reject") ? .destructive : .normal) {
                answer(option.id)
            }
        }
        return BubbleDraft(id: approvalID(request.id), symbol: SharedSymbols.approval, tint: .orange, title: request.heading,
                           body: String(request.detail.prefix(240)), actions: actions, macOnly: true)
    }

    /// An unknown Telegram user sent /start. Allow adds them; nothing else about them reaches the chat.
    func telegramPairing(_ request: TelegramBridge.Pending, allow: @escaping () -> Void, deny: @escaping () -> Void) {
        bubbles.show(Self.telegramPairingBubble(request, allow: allow, deny: deny))
        chime()
    }

    static func telegramPairingBubble(_ request: TelegramBridge.Pending, allow: @escaping () -> Void, deny: @escaping () -> Void) -> BubbleDraft {
        let user = request.user
        let handle = user.username.map { "@\($0), " } ?? ""
        return BubbleDraft(id: telegramID(user.id), symbol: SharedSymbols.sourceTelegram, tint: .blue,
                      title: "Telegram user \(user.displayName) (\(handle)id \(user.id)) wants to connect",
                      body: "Allow them to chat with \(ConfigStore.shared.config.pet.name) from Telegram?",
                      actions: [.init("allow", "Allow", style: .primary, run: allow), .init("deny", "Deny", style: .destructive, run: deny)], macOnly: true)
    }

    /// The bubble for a phone that sent a valid pairing code. Allow gives it a token that reads and changes tasks on this Mac, so the
    /// bubble says so and expires with the code.
    static func remotePairingBubble(_ request: RemotePairingRequest, machine: String, allow: @escaping () -> Void, deny: @escaping () -> Void) -> BubbleDraft {
        BubbleDraft(id: remotePairingID(request.id), symbol: SharedSymbols.sourceIPhone, tint: .blue,
               title: "Allow \(request.deviceName) to connect to \(machine)?",
               body: "This device asked to pair with the remote API. Only allow it if you just scanned the pairing code yourself.",
               actions: [.init("allow", "Allow", style: .primary, run: allow), .init("deny", "Deny", style: .destructive, run: deny)],
               expires: request.created.addingTimeInterval(RemoteService.codeLifetime), macOnly: true)
    }

    /// Too many requests without a valid token. One bubble per lockout, replaced if it comes again.
    static func remoteBlockedBubble() -> BubbleDraft {
        BubbleDraft(id: "remote:blocked", symbol: "exclamationmark.shield", tint: .orange, title: "Remote API: blocked requests",
               body: "Several requests without a valid device token arrived. The remote API ignores unauthenticated requests for five minutes.",
               expires: Date().addingTimeInterval(60))
    }

    static func remotePairingID(_ id: String) -> String { "remote-pairing:\(id)" }

    func clearTelegramPairing(id: Int64) {
        bubbles.dismiss(Self.telegramID(id))
    }

    static func telegramID(_ id: Int64) -> String { "telegram:\(id)" }

    func clearApproval(id: UUID) {
        bubbles.dismiss(Self.approvalID(id))
        notifier.clearApproval(id: id)
    }

    func signal(_ signal: Signal) {
        let url = signal.url
        var actions: [BubbleDraft.Button] = []
        if let url { actions.append(.init("open", "Open", style: .primary) { NSWorkspace.shared.open(url) }) }
        if let prompt = signal.ask {
            actions.append(.init("ask", "Ask \(ConfigStore.shared.config.pet.name)") { [weak self] in self?.ask(prompt) })
        }
        let quiet = signal.mood == .done
        let open = store(NotificationDraft(signal: signal))
        bubbles.show(BubbleDraft(id: "signal:\(signal.id)", symbol: signal.symbol, tint: quiet ? .green : signal.mood == .failed ? .red : .orange,
                            title: signal.label, subtitle: signal.subtitle, body: signal.title, actions: actions,
                            onTap: open ?? url.map { link in { NSWorkspace.shared.open(link) } },
                            expires: Date().addingTimeInterval(quiet ? 15 : 40)))
        if !quiet { chime() }
        if alsoSystemNotifications { notifier.announceSignal(signal) }
    }

    /// A bubble from an automation: a reminder, a poll result, a shell or prompt answer, or an approval question.
    func automation(_ notice: AutomationNotice) {
        let open: (() -> Void)? = notice.notificationID.map { id in { [weak self] in self?.openNotification(id) } }
        bubbles.show(Self.automationBubble(notice, dismiss: { [weak self] in self?.bubbles.dismiss(notice.id) }, open: open, opener: urlOpener))
        chime()
        if alsoSystemNotifications || notice.systemNotification { notifier.announceAutomation(notice) }
    }

    static func automationBubble(_ notice: AutomationNotice, dismiss: @escaping () -> Void, open: (() -> Void)?,
                                 opener: URLOpener = UnsupportedURLOpener()) -> BubbleDraft {
        let tint: BubbleTint
        switch notice.tint {
        case .info: tint = .cyan
        case .good: tint = .green
        case .bad: tint = .red
        case .warn: tint = .orange
        }
        let actions = notice.buttons.enumerated().map { index, button in
            BubbleDraft.Button(button.openURL == nil ? "button:\(index)" : Bubble.Action.openURLID, button.title,
                               style: button.primary ? .primary : button.destructive ? .destructive : .normal) {
                dismiss()
                if let url = button.openURL { try? opener.open(url) }
                button.run()
            }
        }
        return BubbleDraft(id: notice.id, symbol: notice.symbol, tint: tint, title: notice.title, subtitle: notice.subtitle, body: notice.body,
                      actions: actions, onTap: open, expires: notice.expires.map { Date().addingTimeInterval($0) }, macOnly: notice.macOnly)
    }

    func chat(_ title: String, detail: String = "Click to open the chat.") {
        bubbles.show(BubbleDraft(id: "chat", symbol: "bubble.left.fill", tint: .accent, title: title, body: detail,
                            actions: [.init("open-chat", "Open chat", style: .primary) { [weak self] in self?.openChat() }],
                            onTap: { [weak self] in self?.openChat() },
                            expires: Date().addingTimeInterval(20)))
        chime()
        if alsoSystemNotifications { notifier.announceChat(title) }
    }

    /// A meeting summary was written. Clicking opens it.
    func meetingSummary(_ url: URL) {
        let open: () -> Void = { NSWorkspace.shared.open(url) }
        bubbles.show(BubbleDraft(id: "meeting-summary", symbol: "doc.text.fill", tint: .green, title: "Meeting summary ready",
                            body: url.deletingLastPathComponent().lastPathComponent,
                            actions: [.init("open-summary", "Open summary", style: .primary) { open() }], onTap: open,
                            expires: Date().addingTimeInterval(60)))
        chime()
        if alsoSystemNotifications { notifier.announceMeetingSummary(url) }
    }

    static let taskSuggestionsID = "task-suggestions"

    /// One info bubble for suggestions that just arrived from a meeting summary or a watcher: the count and the
    /// first title, no buttons. They stay pending until resolved in the Inbox or over MCP. Nil when there are none.
    static func taskSuggestionsBubble(_ added: [TaskSuggestion], review: @escaping () -> Void = {}, now: Date = Date()) -> BubbleDraft? {
        guard let first = added.first else { return nil }
        let title: String
        switch first.origin {
        case .meeting: title = "From your meeting"
        case .automation(_, let name): title = name
        }
        let count = added.count
        return BubbleDraft(id: taskSuggestionsID, symbol: first.source.symbol, tint: .blue, title: title,
                      body: "\(count) \(count == 1 ? "item" : "items") in your inbox\n\(first.title)",
                      onTap: review, expires: now.addingTimeInterval(20))
    }

    /// Replaces the previous one, so a run shows one bubble however many suggestions it stored.
    func taskSuggestions(_ added: [TaskSuggestion], review: @escaping () -> Void = {}) {
        guard var bubble = Self.taskSuggestionsBubble(added, review: review), let first = added.first else { return }
        var source = NotificationItem.systemSource
        if case .automation(let id, _) = first.origin { source = id }
        let lines = added.map { "- " + $0.title }.joined(separator: "\n")
        let draft = NotificationDraft(source: source, type: .other, title: bubble.title,
                                      summary: "\(added.count) \(added.count == 1 ? "item" : "items") in your inbox",
                                      description: lines + "\n\nAdd or skip them in the Tasks section.")
        if let show = store(draft) { bubble.onTap = show }
        bubbles.show(bubble)
        chime()
    }

    /// Shows the bubble and returns whether there was one to show.
    @discardableResult
    static func showTaskSuggestions(_ added: [TaskSuggestion], in store: BubbleStore, review: @escaping () -> Void = {}) -> Bool {
        guard let bubble = taskSuggestionsBubble(added, review: review) else { return false }
        store.show(bubble)
        return true
    }

    /// What happened while the user was away, one clickable line per kind of news.
    func welcomeBack(_ digest: ActivityDigest, away: TimeInterval, open: @escaping (ActivityDigest.Target) -> Void,
                     showAll: @escaping () -> Void) {
        bubbles.show(Self.digestBubble(digest, id: WelcomeBack.bubbleID, title: "Welcome back", subtitle: Self.awayText(away),
                                       petName: ConfigStore.shared.config.pet.name, open: open, showAll: showAll))
        if digest.items.contains(where: \.isUrgent) { chime() }
    }

    static let digestLineLimit = 5

    /// A summary bubble for any digest: up to five lines, the last one "and N more" when it does not fit.
    static func digestBubble(_ digest: ActivityDigest, id: String, title: String, subtitle: String?, petName: String,
                             open: @escaping (ActivityDigest.Target) -> Void, showAll: @escaping () -> Void,
                             expires: TimeInterval = 180, now: Date = Date()) -> BubbleDraft {
        let fits = digest.items.count <= digestLineLimit
        let shown = fits ? digest.items : Array(digest.items.prefix(digestLineLimit - 1))
        var lines = shown.enumerated().map { index, item in
            let line = digestLine(item, petName: petName)
            let target = item.target
            return BubbleDraft.Row(id: "line:\(index)", symbol: line.symbol, tint: line.tint, text: line.text) { if let target { open(target) } else { showAll() } }
        }
        if !fits {
            let rest = digest.items.dropFirst(shown.count).reduce(0) { $0 + $1.count }
            lines.append(BubbleDraft.Row(id: "line:more", symbol: SharedSymbols.more, tint: .secondary, text: "and \(rest) more", run: showAll))
        }
        let urgent = digest.items.contains(where: \.isUrgent)
        return BubbleDraft(id: id, symbol: urgent ? "exclamationmark.bubble.fill" : "sun.max.fill", tint: urgent ? .orange : .accent,
                      title: title, subtitle: subtitle, lines: lines, actions: [.init("show-all", "Show all", run: showAll)],
                      expires: now.addingTimeInterval(expires))
    }

    /// "While you were away (42 min)", or "(1 h 5 min)".
    static func awayText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let span = minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
        return "While you were away (\(span))"
    }

    /// One line of a summary: the thing itself when there is one, a count when there are several.
    static func digestLine(_ item: ActivityDigest.Item, petName: String) -> (symbol: String, tint: BubbleTint, text: String) {
        let n = item.count
        let first = item.events.first
        let name = first?.title ?? ""
        switch item.kind {
        case .sessionNeedsInput:
            return (SharedSymbols.approval, .orange, n == 1 ? "\(name) is waiting for you" : "\(n) agents are waiting for you")
        case .sessionFailed:
            return ("xmark.octagon.fill", .red, n == 1 ? "\(name) failed" : "\(n) agents failed")
        case .sessionDone:
            return (SharedSymbols.done, .green, n == 1 ? "\(name) finished" : "\(n) agents finished")
        case .alertOpened:
            let failing = item.isUrgent
            let symbol = n == 1 ? (first?.extra[ActivityEvent.AlertKey.symbol] ?? "bell.fill") : "bell.badge.fill"
            return (symbol, failing ? .red : .orange, n == 1 ? alertText(first) : "\(n) new alerts")
        case .alertResolved:
            return ("checkmark.seal.fill", .green, n == 1 ? "Cleared: " + alertText(first) : "\(n) alerts cleared")
        case .taskSuggested:
            return (SharedSymbols.tasks, .accent, n == 1 ? "New in your inbox: \(name)" : "\(n) new inbox items")
        case .meetingSummary:
            return ("doc.text.fill", .green, n == 1 ? "Meeting summary ready: \(name)" : "\(n) meeting summaries ready")
        case .chatFinished:
            return ("bubble.left.fill", .accent, name.isEmpty ? "\(petName) finished your task" : name)
        case .automationBubble:
            let tint: BubbleTint
            switch first?.extra[ActivityEvent.AutomationKey.tint] {
            case "good": tint = .green
            case "bad": tint = .red
            case "warn": tint = .orange
            default: tint = .cyan
            }
            guard n == 1, let first else { return ("bell.fill", .cyan, "\(n) updates from automations") }
            let detail = first.detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return ("bell.fill", tint, detail.isEmpty || detail == first.title ? first.title : "\(first.title): \(detail)")
        default:
            return ("sparkle", .secondary, n == 1 ? name : "\(n) more updates")
        }
    }

    /// "CI failed: irtaza/ironpet #84", from the alert's label and what it is about.
    private static func alertText(_ event: ActivityEvent?) -> String {
        guard let event else { return "" }
        let about = event.detail.isEmpty ? event.title : event.detail
        return event.extra[ActivityEvent.AlertKey.label].map { "\($0): \(about)" } ?? about
    }

    /// The morning brief or the day's recap from a `digest` automation. Open shows it on the Today page.
    func brief(_ brief: Brief, automation: Automation, open: @escaping () -> Void) {
        var bubble = Self.briefBubble(brief, automation: automation, now: Date(), open: open)
        let draft = NotificationDraft(source: automation.id, type: .digest, title: bubble.title,
                                      summary: brief.isEmpty ? "Nothing to report" : brief.lines.first.map { NotificationDraft.summary(of: $0) } ?? "",
                                      description: brief.isEmpty ? "Nothing to report" : brief.lines.joined(separator: "\n"))
        if let show = store(draft) { bubble.onTap = show }
        bubbles.show(bubble)
        guard !brief.isEmpty else { return }
        chime()
        if alsoSystemNotifications || automation.presentation.notification == true {
            notifier.announceAutomation(AutomationNotice(id: bubble.id, symbol: bubble.symbol, title: bubble.title, subtitle: bubble.subtitle,
                                                         body: bubble.body, automationIDs: [automation.id]))
        }
    }

    static func briefID(_ kind: Brief.Kind) -> String { "digest:\(kind.rawValue)" }

    /// Stays until the end of the day, since it comes once a day. An empty one, which only Run now shows, goes in 15 seconds.
    static func briefBubble(_ brief: Brief, automation: Automation, now: Date, calendar: Calendar = .current,
                            open: @escaping () -> Void) -> BubbleDraft {
        var day = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        let expires: Date?
        if let seconds = automation.presentation.expiresSeconds {
            expires = now.addingTimeInterval(seconds)
        } else if brief.isEmpty {
            expires = now.addingTimeInterval(15)
        } else {
            expires = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        }
        return BubbleDraft(id: briefID(brief.kind), symbol: automation.presentation.symbol ?? brief.kind.symbol,
                      tint: brief.kind == .brief ? .orange : .indigo,
                      title: automation.action.title ?? brief.kind.title, subtitle: (brief.kind == .recap ? brief.window.start : now).formatted(day),
                      body: brief.isEmpty ? "Nothing to report" : brief.lines.prefix(4).joined(separator: "\n"),
                      actions: [.init("open", "Open", style: .primary, run: open)], onTap: open, expires: expires)
    }

    /// Small talk from the Actions menu.
    func say(_ text: String) {
        bubbles.show(BubbleDraft(id: "say", symbol: SharedSymbols.pet, tint: .accent, title: ConfigStore.shared.config.pet.name, body: text,
                            expires: Date().addingTimeInterval(8)))
    }

    private func chime() {
        NSSound(named: "Pop")?.play()
    }

    static func approvalID(_ id: UUID) -> String { "approval:\(id.uuidString)" }
}
