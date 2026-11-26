import CoreGraphics
import Foundation

/// Turns Fn (globe) key events into dictation actions. Pure logic: the caller feeds events and a clock, so tests need no
/// event tap.
///
/// - Press while idle starts recording. Release after `tapThreshold` or more stops it (hold to talk).
/// - Release sooner than that leaves recording on (a tap toggles it on). The next press stops it.
/// - Another key pressed while Fn is down makes it a combination (Fn+arrow, emoji picker). A recording this press
///   started is cancelled, and the release does nothing.
final class FnKeyDetector {
    enum Event { case fnDown, fnUp, otherKeyDown }
    enum Action: Equatable { case start, stop, cancel }

    /// A press shorter than this is a tap.
    static let tapThreshold: TimeInterval = 0.3

    private let now: () -> TimeInterval
    private let isRecording: () -> Bool
    private var downAt: TimeInterval?
    private var startedByThisPress = false
    private var ignoreRelease = false

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isRecording: @escaping () -> Bool) {
        self.now = now
        self.isRecording = isRecording
    }

    func handle(_ event: Event) -> Action? {
        switch event {
        case .fnDown:
            guard downAt == nil else { return nil } // Key repeat or a duplicate flags event.
            downAt = now()
            ignoreRelease = false
            if isRecording() {
                startedByThisPress = false
                ignoreRelease = true
                return .stop
            }
            startedByThisPress = true
            return .start
        case .fnUp:
            guard let down = downAt else { return nil }
            downAt = nil
            defer { startedByThisPress = false; ignoreRelease = false }
            if ignoreRelease { return nil }
            // Esc may have cancelled the recording while Fn was held. Stopping then would start a new one.
            guard isRecording() else { return nil }
            return now() - down >= Self.tapThreshold ? .stop : nil
        case .otherKeyDown:
            guard downAt != nil, !ignoreRelease else { return nil }
            ignoreRelease = true
            let started = startedByThisPress
            startedByThisPress = false
            return started ? .cancel : nil
        }
    }

    /// Forget a press in progress, for when the monitor is removed.
    func reset() {
        downAt = nil
        startedByThisPress = false
        ignoreRelease = false
    }
}

/// Input Monitoring, the permission a listen-only event tap needs.
protocol InputMonitoringAccess {
    /// True when granted. Asks macOS to show its prompt when it is not.
    func request() -> Bool
}

struct SystemInputMonitoringAccess: InputMonitoringAccess {
    func request() -> Bool {
        CGPreflightListenEventAccess() || CGRequestListenEventAccess()
    }
}

/// A source of Fn events that can be installed and removed.
protocol FnEventSource: AnyObject {
    var onEvent: ((FnKeyDetector.Event) -> Void)? { get set }
    func install() -> Bool
    func remove()
}

/// Owns the Fn event source for dictation. It installs nothing and asks for nothing unless the dictation shortcut is
/// "fn".
final class FnDictationTrigger {
    static let configValue = "fn"

    private let access: InputMonitoringAccess
    private let source: FnEventSource
    private let detector: FnKeyDetector
    private let perform: (FnKeyDetector.Action) -> Void
    private(set) var isInstalled = false

    init(access: InputMonitoringAccess, source: FnEventSource, detector: FnKeyDetector,
         perform: @escaping (FnKeyDetector.Action) -> Void) {
        self.access = access
        self.source = source
        self.detector = detector
        self.perform = perform
        source.onEvent = { [weak self] event in
            guard let self, let action = self.detector.handle(event) else { return }
            self.perform(action)
        }
    }

    /// Call whenever the config changes. `shortcut` is the dictation shortcut to honour, nil when off.
    func update(shortcut: String?) {
        let wanted = shortcut?.lowercased() == Self.configValue
        if wanted, !isInstalled {
            guard access.request() else { return }
            isInstalled = source.install()
        } else if !wanted, isInstalled {
            source.remove()
            detector.reset()
            isInstalled = false
        }
    }
}

/// A listen-only CGEventTap. It never changes or swallows an event, so Fn+key combinations and the emoji picker work.
final class FnEventTap: FnEventSource {
    var onEvent: ((FnKeyDetector.Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false

    func install() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let this = Unmanaged<FnEventTap>.fromOpaque(refcon).takeUnretainedValue()
            this.receive(type: type, flags: event.flags)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func remove() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        fnIsDown = false
    }

    private func receive(type: CGEventType, flags: CGEventFlags) {
        switch type {
        case .flagsChanged:
            let down = flags.contains(.maskSecondaryFn)
            guard down != fnIsDown else { return }
            fnIsDown = down
            onEvent?(down ? .fnDown : .fnUp)
        case .keyDown:
            if fnIsDown { onEvent?(.otherKeyDown) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }
}
