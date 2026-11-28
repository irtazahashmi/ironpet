import AppIntents
import Foundation

/// Hands a start request from the system (the Action button, Shortcuts, the lock screen) to the voice model of the running app.
///
/// The intent can run before the tabs exist, because the system launches the app in the background for it. The request then waits
/// until the tabs register their handler, or until the timeout passes.
@MainActor
final class VoiceLaunch {
    static let shared = VoiceLaunch()

    /// How long a request waits for the tabs to come up. An unpaired app never registers a handler.
    static var timeout: Duration = .seconds(10)

    /// Starts voice mode and returns true when the phone listens. Set by the tabs, cleared when they go away.
    var handler: (() async -> Bool)? {
        didSet { if handler != nil { flush() } }
    }
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Starts voice mode now, or as soon as the tabs register. False when nothing registered within the timeout or the start failed.
    func start() async -> Bool {
        if let handler { return await handler() }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.waiting.removeValue(forKey: id)?.resume(returning: false)
        }
        defer { timer.cancel() }
        let registered = await withCheckedContinuation { waiting[id] = $0 }
        guard registered, let handler else { return false }
        return await handler()
    }

    private func flush() {
        let all = waiting
        waiting = [:]
        for continuation in all.values { continuation.resume(returning: true) }
    }
}

enum VoiceIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        "IronPet could not start listening. Open the app and check that it is paired with your Mac."
    }
}

/// The Action button and lock screen entry to voice mode. `AudioRecordingIntent` lets the system run it in the app's process in the
/// background, with the microphone, without unlocking the phone. Needs iOS 18; on iOS 17 the shortcut is not offered.
@available(iOS 18.0, *)
struct StartVoiceModeIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start voice mode"
    // App Store Connect rejects intent metadata that names an Apple product (ITMS-90626), so no "Mac" or "iPhone" here.
    static let description = IntentDescription("Starts listening. IronPet sends what you say to your pet's chat and reads the summary of the reply aloud.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await VoiceLaunch.shared.start() else { throw VoiceIntentError.notReady }
        return .result()
    }
}

/// Lists the intent in Shortcuts and in the Action button's shortcut picker.
@available(iOS 18.0, *)
struct IronPetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartVoiceModeIntent(),
                    phrases: ["Start voice mode in \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Voice mode", systemImageName: "waveform")
    }
}
