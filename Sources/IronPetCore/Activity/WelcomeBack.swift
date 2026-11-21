import Foundation

/// When the user comes back after being away, sums up what happened meanwhile in one bubble and folds away the short-lived
/// bubbles it covers. Reads only the activity log and the live stores; nothing runs or leaves the Mac.
@MainActor
package final class WelcomeBack {
    package struct Environment {
        package init(
            now: @escaping () -> Date = { Date() },
            presence: PresenceSource = UnsupportedPresenceSource(),
            isPresent: @escaping () -> Bool = { false },
            presenceNotNeeded: @escaping () -> Void = {},
            isEnabled: @escaping () -> Bool = { true },
            threshold: @escaping () -> TimeInterval = { 5 * 60 }
        ) {
            self.now = now
            self.presence = presence
            self.isPresent = isPresent
            self.presenceNotNeeded = presenceNotNeeded
            self.isEnabled = isEnabled
            self.threshold = threshold
        }

        package var now: () -> Date = { Date() }
        /// Idle time, screen lock and wake, the same source as the automation clock.
        package var presence: PresenceSource = UnsupportedPresenceSource()
        /// A meeting is being recorded or a call is on: the user is at the Mac even without typing. Asked only once the
        /// user would otherwise count as away, so a costly check does not run while they type.
        package var isPresent: () -> Bool = { false }
        /// Called on ticks where presence does not matter, so a background check can stop.
        package var presenceNotNeeded: () -> Void = {}
        package var isEnabled: () -> Bool = { true }
        /// How long without input counts as away. The app passes `reminders.idleResetMinutes`.
        package var threshold: () -> TimeInterval = { 5 * 60 }
    }

    package static let bubbleID = "welcome-back"
    /// The id of the bubble that lists the tasks due today. `Announcer` shows it under this id.
    package static let tasksDueID = "task-due"
    /// The daily brief's bubbles. A brief already says what is going on, so a summary right after it would repeat it.
    package static let digestPrefix = "digest:"
    package static let digestQuiet: TimeInterval = 30 * 60

    package var env: Environment
    /// What is true now, so items the user already dealt with drop out.
    package var live: () -> ActivityDigest.LiveState = { .init() }
    /// Shows the summary: the digest and how long the user was away.
    package var show: (_ digest: ActivityDigest, _ away: TimeInterval) -> Void = { _, _ in }

    private let log: ActivityLog
    package let bubbles: BubbleStore
    package private(set) var tracker = AwayTracker()
    /// A return seen while the screen was still locked, shown once it unlocks.
    package private(set) var pendingSince: Date?
    package private(set) var lastDigest: ActivityDigest?

    package init(log: ActivityLog, bubbles: BubbleStore, env: Environment = Environment()) {
        self.log = log
        self.bubbles = bubbles
        self.env = env
    }

    /// Call every couple of seconds.
    package func tick() {
        let now = env.now()
        let idle = env.presence.idleOrZero(), threshold = env.threshold()
        let woke = tracker.lastSample.map(env.presence.wokeSince) ?? false
        let needsPresence = idle >= threshold || woke || tracker.awaySince != nil
        if !needsPresence { env.presenceNotNeeded() }
        let present = needsPresence && env.isPresent()
        let transition = tracker.sample(now: now, idleSeconds: idle, threshold: threshold, present: present, woke: woke)
        if case .returned(let since, _) = transition { pendingSince = min(pendingSince ?? since, since) }
        guard let since = pendingSince, !env.presence.isScreenLocked() else { return }
        pendingSince = nil
        summarize(DateInterval(start: since, end: max(since, now)))
    }

    /// Builds the summary of `window` and shows it, unless there is nothing to say, it would only repeat what is on screen,
    /// or a daily brief or recap appeared in the last 30 minutes. One that is still up from earlier does not count: it
    /// stays until midnight.
    package func summarize(_ window: DateInterval) {
        guard env.isEnabled() else { return }
        let now = env.now()
        if bubbles.lastShown(prefix: Self.digestPrefix).map({ now.timeIntervalSince($0) < Self.digestQuiet }) == true { return }
        let events = log.events(in: window)
        var state = live()
        // A task due bubble waits for Done or Snooze, so it keeps its own place.
        if bubbles.bubbles.contains(where: { $0.id == Self.tasksDueID }) { state.excluded.insert(.taskDue) }
        let digest = ActivityDigest.build(events: events, window: window, live: state)
        lastDigest = digest
        guard !digest.isEmpty else { return }
        if digest.count == 1, let only = digest.items.first?.events.first,
           bubbles.bubbles.contains(where: { $0.id == Self.bubbleID(for: only) }) { return }
        let covered = Set(events.map(Self.bubbleID(for:)))
        for bubble in bubbles.bubbles where bubble.expires != nil && covered.contains(bubble.id)
            && (bubbles.shownAt[bubble.id] ?? .distantPast) >= window.start {
            bubbles.dismiss(bubble.id)
        }
        show(digest, window.duration)
    }

    /// The bubble the app showed for an event, by the ids `Announcer` and the automation service use.
    package static func bubbleID(for event: ActivityEvent) -> String {
        switch event.kind {
        case .sessionNeedsInput, .sessionFailed, .sessionDone: return "session:\(event.ref)"
        case .alertOpened: return "signal:\(event.ref)"
        case .taskSuggested: return "task-suggestions"
        case .taskDue: return Self.tasksDueID
        case .meetingSummary: return "meeting-summary"
        case .chatFinished: return "chat"
        default: return event.ref
        }
    }

    /// The live state from the app's stores at `now`.
    package static func liveState(sessions: [AgentSession], signals: [Signal], tasks: [TaskItem], suggestions: [TaskSuggestion], now: Date) -> ActivityDigest.LiveState {
        var sessionKinds: [String: ActivityEvent.Kind] = [:]
        var idleSince: [String: Date] = [:]
        for session in sessions {
            switch session.status {
            case .needsInput: sessionKinds[session.id] = .sessionNeedsInput
            case .failed: sessionKinds[session.id] = .sessionFailed
            case .done: sessionKinds[session.id] = .sessionDone
            // The sweep makes a quiet session idle without touching `updatedAt`, so this is its last event.
            case .idle where !session.ended: idleSince[session.id] = session.updatedAt
            default: break
            }
        }
        return ActivityDigest.LiveState(sessions: sessionKinds, idleSince: idleSince, openAlerts: Set(signals.map(\.id)),
                                        waitingSuggestions: Set(suggestions.map(\.id)),
                                        dueTasks: Set(tasks.filter { TaskDue.hasCome($0, now: now) }.map(\.id)))
    }
}
