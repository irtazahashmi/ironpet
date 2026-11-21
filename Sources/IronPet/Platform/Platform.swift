import Foundation

/// Every adapter the core code can use, in one value. `AppDelegate` builds the Mac one, tests build a fake one, and nothing
/// looks an adapter up globally: whoever needs one receives it through an initialiser.
struct Platform: Sendable {
    var secrets: SecretStore
    var processes: ProcessSpawner
    var log: LogSink
    var appInfo: AppInfo
    var clock: WallClock

    struct Capability: Equatable, Sendable {
        let name: String
        let supported: Bool
    }

    /// Which adapters are real and which are `Unsupported`.
    var capabilities: [Capability] {
        [
            Capability(name: "SecretStore", supported: secrets.isSupported),
            Capability(name: "ProcessSpawner", supported: processes.isSupported),
            Capability(name: "LogSink", supported: log.isSupported),
            Capability(name: "AppInfo", supported: appInfo.isSupported),
            Capability(name: "WallClock", supported: clock.isSupported),
        ]
    }

    /// A platform that can do nothing. Owners start with it, and `AppDelegate` replaces it with the Mac one.
    static var unsupported: Platform {
        Platform(secrets: UnsupportedSecretStore(), processes: UnsupportedProcessSpawner(), log: UnsupportedLogSink(),
                 appInfo: UnsupportedAppInfo(), clock: UnsupportedClock())
    }
}
