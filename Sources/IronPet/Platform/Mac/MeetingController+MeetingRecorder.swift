import Foundation

/// The Mac adapter for `MeetingRecorder` is the controller itself. It already owns the audio sources, the chunk pipeline and the
/// summary run, so wrapping it would only repeat each member.
extension MeetingController: MeetingRecorder {
    nonisolated var isSupported: Bool { true }
}
