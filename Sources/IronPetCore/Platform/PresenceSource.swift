import Foundation

/// What the core code asks the machine about the person at it: how long since the last keyboard or mouse event, whether the
/// screen is locked, whether the machine woke from sleep, and which apps hold the microphone for a call. `AutomationEngine`
/// and `WelcomeBack` read it, and `Presence` combines it with the meeting recorder. The Mac adapter is `MacPresenceSource`.
@MainActor
package protocol PresenceSource: AnyObject {
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
    package nonisolated var isSupported: Bool { true }
}

/// Reports a user who is always at the keyboard, so nothing counts as away.
@MainActor
package final class UnsupportedPresenceSource: PresenceSource {
    package var platform = PlatformName.current
    package nonisolated var isSupported: Bool { false }

    package nonisolated init() {}

    package func idleSeconds() throws -> TimeInterval { throw CapabilityError.unsupported(capability: "PresenceSource", platform: platform) }
    package func isScreenLocked() -> Bool { false }
    package func wokeSince(_ date: Date) -> Bool { false }
    package func micCalls() -> Set<String> { [] }
    package func stopMicWatch() {}
}

extension PresenceSource {
    /// The idle time consumers act on: zero (at the keyboard) when the source cannot tell.
    package func idleOrZero() -> TimeInterval { (try? idleSeconds()) ?? 0 }
}
