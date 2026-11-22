import Foundation

extension Platform {
    /// The capability each adapter gives the client that hosts it. Adapters with no entry here are local plumbing, such as the log
    /// sink, that no server request ever needs.
    package static let capabilityForAdapter: [String: ClientCapability] = [
        "CaptureControl": .screen,
        "PresenceSource": .presence,
        "SecretStore": "secrets",
        "ProcessSpawner": "processes",
        "LogSink": "log",
        "AppInfo": "appInfo",
        "WallClock": "clock",
        "MeetingRecorder": "meetings",
        "SpeechOutput": "speech",
        "PetAssets": "petAssets",
        "FileIntake": "files",
        "URLOpener": "openURL",
        "AudioTranscoder": "audio",
    ]

    /// What a client built on this platform advertises: one capability for each adapter that is real, none for an `Unsupported` one.
    /// `extra` adds what the adapters do not cover, such as the Mac's desktop tools.
    package func clientCapabilities(extra: [ClientCapability] = []) -> [ClientCapability] {
        let own = capabilities.compactMap { $0.supported ? Self.capabilityForAdapter[$0.name] : nil }
        return Array(Set(own + extra)).sorted()
    }
}
