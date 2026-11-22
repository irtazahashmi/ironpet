import Foundation

/// `PresenceSource` that reads the idle time from client sessions. A desktop client reports when its person last used the keyboard
/// or mouse (`ClientSession.lastInputAt`), and the user counts as at their desk when any desktop client says so.
///
/// The local client has no one to report for it, so each read first asks `local` how long the machine has been idle and records
/// that as the local session's `lastInputAt`. Lock, wake and microphone state are facts about this machine only, so they come
/// from `local` as they did before.
@MainActor
package final class SessionPresence: PresenceSource {
    private let registry: ClientRegistry
    private let local: PresenceSource
    private let now: () -> Date

    package init(registry: ClientRegistry, local: PresenceSource, now: @escaping () -> Date = Date.init) {
        self.registry = registry
        self.local = local
        self.now = now
    }

    package nonisolated var isSupported: Bool { true }

    /// Seconds since the most recent input on any desktop client. Throws `CapabilityError.unsupported` when none reports.
    package func idleSeconds() throws -> TimeInterval {
        let at = now()
        if let session = registry.local, session.advertises(.presence), let idle = try? local.idleSeconds() {
            // The adapter's answer is the truth for this machine, even when it says the person was idle longer than before.
            registry.update(session.id) { $0.lastInputAt = at.addingTimeInterval(-idle) }
        }
        let inputs = registry.sessions.filter { $0.kind.isDesktop }.compactMap(\.lastInputAt)
        guard let latest = inputs.max() else {
            throw CapabilityError.unsupported(capability: "PresenceSource", platform: registry.local?.kind.platformName ?? PlatformName.current)
        }
        return max(0, at.timeIntervalSince(latest))
    }

    package func isScreenLocked() -> Bool { local.isScreenLocked() }
    package func wokeSince(_ date: Date) -> Bool { local.wokeSince(date) }
    package func micCalls() -> Set<String> { local.micCalls() }
    package func stopMicWatch() { local.stopMicWatch() }
}
