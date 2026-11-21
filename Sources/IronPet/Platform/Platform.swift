import Foundation

/// Every adapter the core code can use, in one value. `AppDelegate` builds the Mac one, tests build a fake one, and nothing
/// looks an adapter up globally: whoever needs one receives it through an initialiser.
struct Platform: @unchecked Sendable { // The main-actor adapters are used only from the main actor.
    var secrets: SecretStore
    var processes: ProcessSpawner
    var log: LogSink
    var appInfo: AppInfo
    var clock: WallClock
    var meetings: MeetingRecorder
    var capture: CaptureControl
    var speech: SpeechOutput
    var pets: PetAssets
    var files: FileIntake
    var presence: PresenceSource
    var opener: URLOpener
    var audio: AudioTranscoder

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
            Capability(name: "MeetingRecorder", supported: meetings.isSupported),
            Capability(name: "CaptureControl", supported: capture.isSupported),
            Capability(name: "SpeechOutput", supported: speech.isSupported),
            Capability(name: "PetAssets", supported: pets.isSupported),
            Capability(name: "FileIntake", supported: files.isSupported),
            Capability(name: "PresenceSource", supported: presence.isSupported),
            Capability(name: "URLOpener", supported: opener.isSupported),
            Capability(name: "AudioTranscoder", supported: audio.isSupported),
        ]
    }

    /// A platform that can do nothing. Owners start with it, and `AppDelegate` replaces it with the Mac one.
    @MainActor
    static var unsupported: Platform {
        Platform(secrets: UnsupportedSecretStore(), processes: UnsupportedProcessSpawner(), log: UnsupportedLogSink(),
                 appInfo: UnsupportedAppInfo(), clock: UnsupportedClock(), meetings: UnsupportedMeetingRecorder(),
                 capture: UnsupportedCaptureControl(), speech: UnsupportedSpeechOutput(), pets: UnsupportedPetAssets(),
                 files: UnsupportedFileIntake(), presence: UnsupportedPresenceSource(),
                 opener: UnsupportedURLOpener(), audio: UnsupportedAudioTranscoder())
    }
}
