import Foundation

/// What the core code asks the machine about the person at it: how long since the last keyboard or mouse event, whether the
/// screen is locked, whether the machine woke from sleep, and which apps hold the microphone for a call. `AutomationEngine`
/// and `WelcomeBack` read it, and `Presence` combines it with the meeting recorder. The Mac adapter is `MacPresenceSource`.
@MainActor
protocol PresenceSource: AnyObject {
    /// False for the `Unsupported` adapter, which `Platform.capabilities` reports.
    nonisolated var isSupported: Bool { get }
    /// Seconds since the last keyboard or mouse event. Throws `CapabilityError.unsupported` where nothing can tell.
    func idleSeconds() throws -> TimeInterval
    func isScreenLocked() -> Bool
    /// Whether the machine woke from sleep after `date`.
    func wokeSince(_ date: Date) -> Bool
    /// The apps holding the microphone as of the last poll. The first call after a stop is empty and starts the polling.
    func micCalls() -> Set<String>
    /// Stops the microphone polling that `micCalls` started.
    func stopMicWatch()
}

extension PresenceSource {
    nonisolated var isSupported: Bool { true }
}

/// Reports a user who is always at the keyboard, so nothing counts as away.
@MainActor
final class UnsupportedPresenceSource: PresenceSource {
    var platform = PlatformName.current
    nonisolated var isSupported: Bool { false }

    nonisolated init() {}

    func idleSeconds() throws -> TimeInterval { throw CapabilityError.unsupported(capability: "PresenceSource", platform: platform) }
    func isScreenLocked() -> Bool { false }
    func wokeSince(_ date: Date) -> Bool { false }
    func micCalls() -> Set<String> { [] }
    func stopMicWatch() {}
}

extension PresenceSource {
    /// The idle time consumers act on: zero (at the keyboard) when the source cannot tell.
    func idleOrZero() -> TimeInterval { (try? idleSeconds()) ?? 0 }
}
