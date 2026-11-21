import AppKit
import IronPetCore

extension AudioApps {
    /// Regular apps that are running, without ironpet itself, meeting apps first.
    static func running(ownBundleID: String? = Bundle.main.bundleIdentifier, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [AudioApp] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .compactMap { app -> AudioApp? in
                guard let id = app.bundleIdentifier else { return nil }
                return AudioApp(bundleID: id, name: app.localizedName ?? id)
            }
        return candidates(from: apps, ownBundleID: ownBundleID)
    }
}
