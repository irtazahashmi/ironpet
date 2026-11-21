import Foundation

/// Whether the user is at the Mac without typing: a meeting is being recorded, or an app holds the microphone for a call.
/// Uses meeting call detection while it runs; otherwise `micCalls`, which needs no permission.
package struct Presence {
    package init(meetingActive: @escaping () -> Bool, detectedCalls: @escaping () -> Set<String>?, micCalls: @escaping () -> Set<String>) {
        self.meetingActive = meetingActive
        self.detectedCalls = detectedCalls
        self.micCalls = micCalls
    }

    package var meetingActive: () -> Bool
    /// The apps meeting call detection counts as calls, or nil while it is not running.
    package var detectedCalls: () -> Set<String>?
    /// The apps holding the microphone as of the last background poll, for when meeting call detection is off.
    package var micCalls: () -> Set<String>

    package func isPresent() -> Bool {
        if meetingActive() { return true }
        return !(detectedCalls() ?? micCalls()).isEmpty
    }
}
