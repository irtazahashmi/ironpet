import Foundation

/// A process that is capturing microphone input.
package struct MicClient: Equatable {
    package init(pid: pid_t, bundleID: String) {
        self.pid = pid
        self.bundleID = bundleID
    }

    package var pid: pid_t
    package var bundleID: String
}

/// Which mic users count as a call, and which app each one belongs to. Kept in one place.
package enum CallApps {
    /// Never a call: voice assistants, dictation and system daemons.
    package static let ignoredPrefixes = [
        "com.apple.Siri", "com.apple.assistant", "com.apple.speech", "com.apple.SpeechRecognition",
        "com.apple.corespeech", "com.apple.voicememos", "com.apple.VoiceOver", "com.apple.accessibility",
        "com.apple.audio", "com.apple.coreaudio", "com.apple.controlcenter", "com.apple.dictation",
        "com.electron.wispr-flow",
    ]

    /// Other apps' helper processes report their own bundle IDs. Chrome, Electron apps and WhatsApp use a `.helper`
    /// suffix, and Safari's web content runs as `com.apple.WebKit.*`.
    package static func parentBundleID(_ id: String) -> String {
        if id.hasPrefix("com.apple.WebKit.") { return "com.apple.Safari" }
        if let range = id.range(of: ".helper", options: .caseInsensitive) { return String(id[..<range.lowerBound]) }
        return id
    }

    /// Whether the built-in list ignores this bundle id.
    package static func isBuiltInIgnored(_ id: String) -> Bool { ignoredPrefixes.contains { id.hasPrefix($0) } }

    /// The app a client belongs to, or nil if it is ironpet, a system service, an assistant or a prefix in `ignored`
    /// (the user's list, matched without regard to case).
    package static func app(for client: MicClient, ownPID: pid_t, ownBundleID: String?, ignored: [String] = []) -> String? {
        guard client.pid != ownPID, !client.bundleID.isEmpty else { return nil }
        let id = parentBundleID(client.bundleID)
        if id == ownBundleID { return nil }
        if isBuiltInIgnored(id) { return nil }
        let lowered = id.lowercased()
        if ignored.contains(where: { !$0.isEmpty && lowered.hasPrefix($0.lowercased()) }) { return nil }
        // Other system processes (coreaudiod, helpers of the OS) are not calls. FaceTime and Safari are.
        if id.hasPrefix("com.apple."), !AudioApps.meetingApps.contains(id), !AudioApps.browsers.contains(id) { return nil }
        return id
    }
}

/// Reports when a non-ignored app has held the microphone for `debounce` seconds, and when it has let go for as long.
/// The process list and the clock are injected, so tests run without audio hardware.
package final class CallDetector {
    package var source: () -> [MicClient]
    package var now: () -> Date
    package var debounce: TimeInterval
    package var ownPID: pid_t
    package var ownBundleID: String?
    /// The user's extra ignored prefixes, read on every tick so a change applies without a restart.
    package var ignored: () -> [String]
    package var onStarted: ((String) -> Void)?
    package var onEnded: ((String) -> Void)?

    /// When each app was first seen holding the mic in the current run, and whether a call was reported for it.
    private var since: [String: Date] = [:]
    private var lastHeld: [String: Date] = [:]
    private var active: Set<String> = []

    package init(source: @escaping () -> [MicClient], now: @escaping () -> Date = Date.init, debounce: TimeInterval = 10,
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier, ownBundleID: String? = Bundle.main.bundleIdentifier,
         ignored: @escaping () -> [String] = { [] }) {
        self.source = source
        self.ignored = ignored
        self.now = now
        self.debounce = debounce
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    package var activeApps: Set<String> { active }

    /// Forgets every app, without reporting an end, for when detection stops.
    package func reset() {
        since = [:]
        lastHeld = [:]
        active = []
    }

    package func tick() {
        let time = now()
        let extra = ignored()
        let holding = Set(source().compactMap { CallApps.app(for: $0, ownPID: ownPID, ownBundleID: ownBundleID, ignored: extra) })
        for id in holding {
            lastHeld[id] = time
            if since[id] == nil { since[id] = time }
            if !active.contains(id), time.timeIntervalSince(since[id]!) >= debounce {
                active.insert(id)
                onStarted?(id)
            }
        }
        for id in Array(since.keys) where !holding.contains(id) {
            if active.contains(id) {
                guard time.timeIntervalSince(lastHeld[id] ?? time) >= debounce else { continue }
                active.remove(id)
                onEnded?(id)
            }
            since[id] = nil
            lastHeld[id] = nil
        }
    }
}
