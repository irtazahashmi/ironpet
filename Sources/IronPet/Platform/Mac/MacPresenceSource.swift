import AppKit
import CoreGraphics

/// Polls Core Audio for apps holding the microphone only while asked to, through `CallMonitor`, so the reads stay off
/// the main thread. The first answer after starting is empty; the next poll, 2 s later, has the real one.
@MainActor
final class MicWatch {
    private let monitor: CallMonitor

    init(monitor: CallMonitor? = nil, ignored: @escaping () -> [String] = { [] }) {
        self.monitor = monitor ?? CallMonitor(detector: CallDetector(source: { [] }, debounce: 0, ignored: ignored))
    }

    var isRunning: Bool { monitor.isRunning }

    /// Starts polling if it is not running, and returns the calls the last finished poll saw.
    func calls() -> Set<String> {
        monitor.start()
        return monitor.detector.activeApps
    }

    func stop() { monitor.stop() }
}

/// When the Mac last woke from sleep, so a gap between timer ticks counts as sleep only after a real wake, not after
/// App Nap or a busy main thread.
@MainActor
final class WakeMonitor {
    static let shared = WakeMonitor()
    private(set) var lastWake: Date?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // Registered on the main queue, so this runs on the main thread.
            MainActor.assumeIsolated { WakeMonitor.shared.lastWake = Date() }
        }
    }

    func woke(since date: Date) -> Bool { lastWake.map { $0 > date } ?? false }
}

/// The Mac adapter for `PresenceSource`: Core Graphics for idle time and the lock state, `NSWorkspace` for wake, and
/// `MicWatch` for calls.
@MainActor
final class MacPresenceSource: PresenceSource {
    private let mic: MicWatch
    /// Test mode sets it through `/test/idle` to stand in for the real idle time.
    var idleOverride: TimeInterval?

    init(ignoredMicApps: @escaping () -> [String] = { [] }) {
        mic = MicWatch(ignored: ignoredMicApps)
    }

    func idleSeconds() throws -> TimeInterval {
        if let idleOverride { return idleOverride }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func isScreenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    func wokeSince(_ date: Date) -> Bool { WakeMonitor.shared.woke(since: date) }
    func micCalls() -> Set<String> { mic.calls() }
    func stopMicWatch() { mic.stop() }
}
