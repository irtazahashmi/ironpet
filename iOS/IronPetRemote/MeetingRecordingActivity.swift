import ActivityKit
import AppIntents
import Foundation

/// The Live Activity of a room recording: a running timer and a Stop control. Shared with the widget extension, which draws it.
struct MeetingRecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// False once Stop was pressed and the audio is being finished.
        var recording: Bool
    }

    /// The timer counts from here, so the system keeps it running while the app sleeps in the background.
    var startedAt: Date
}

extension Notification.Name {
    /// Posted by `StopMeetingRecordingIntent`. The recorder in the app listens for it.
    static let stopMeetingRecording = Notification.Name("dev.ironpet.stopMeetingRecording")
}

/// The Stop button of the Live Activity. The system runs a `LiveActivityIntent` in the app's process, so the app that holds the recorder
/// hears the notification.
struct StopMeetingRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop recording"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .stopMeetingRecording, object: nil)
        return .result()
    }
}
