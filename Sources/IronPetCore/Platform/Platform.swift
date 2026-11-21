import Foundation

/// Every adapter the core code can use, in one value. `AppDelegate` builds the Mac one, tests build a fake one, and nothing
/// looks an adapter up globally: whoever needs one receives it through an initialiser.
package struct Platform: @unchecked Sendable { // The main-actor adapters are used only from the main actor.
    package init(
        secrets: SecretStore,
        processes: ProcessSpawner,
        log: LogSink,
        appInfo: AppInfo,
        clock: WallClock,
        meetings: MeetingRecorder,
        capture: CaptureControl,
        speech: SpeechOutput,
        pets: PetAssets,
        files: FileIntake,
        presence: PresenceSource,
        opener: URLOpener,
        audio: AudioTranscoder
    ) {
        self.secrets = secrets
        self.processes = processes
        self.log = log
        self.appInfo = appInfo
        self.clock = clock
        self.meetings = meetings
        self.capture = capture
        self.speech = speech
        self.pets = pets
        self.files = files
        self.presence = presence
        self.opener = opener
        self.audio = audio
    }

    package var secrets: SecretStore
    package var processes: ProcessSpawner
    package var log: LogSink
    package var appInfo: AppInfo
    package var clock: WallClock
    package var meetings: MeetingRecorder
    package var capture: CaptureControl
    package var speech: SpeechOutput
    package var pets: PetAssets
    package var files: FileIntake
    package var presence: PresenceSource
    package var opener: URLOpener
    package var audio: AudioTranscoder

    package struct Capability: Equatable, Sendable {
        package init(name: String, supported: Bool) {
            self.name = name
            self.supported = supported
        }

        package let name: String
        package let supported: Bool
    }

    /// Which adapters are real and which are `Unsupported`.
    package var capabilities: [Capability] {
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
    package static var unsupported: Platform {
        Platform(secrets: UnsupportedSecretStore(), processes: UnsupportedProcessSpawner(), log: UnsupportedLogSink(),
                 appInfo: UnsupportedAppInfo(), clock: UnsupportedClock(), meetings: UnsupportedMeetingRecorder(),
                 capture: UnsupportedCaptureControl(), speech: UnsupportedSpeechOutput(), pets: UnsupportedPetAssets(),
                 files: UnsupportedFileIntake(), presence: UnsupportedPresenceSource(),
                 opener: UnsupportedURLOpener(), audio: UnsupportedAudioTranscoder())
    }
}
