import Foundation

/// Whether the user is at the Mac without typing: a meeting is being recorded, or an app holds the microphone for a call.
/// Uses meeting call detection while it runs; otherwise `micCalls`, which needs no permission.
struct Presence {
    var meetingActive: () -> Bool
    /// The apps meeting call detection counts as calls, or nil while it is not running.
    var detectedCalls: () -> Set<String>?
    /// The apps holding the microphone as of the last background poll, for when meeting call detection is off.
    var micCalls: () -> Set<String>

    func isPresent() -> Bool {
        if meetingActive() { return true }
        return !(detectedCalls() ?? micCalls()).isEmpty
    }
}
