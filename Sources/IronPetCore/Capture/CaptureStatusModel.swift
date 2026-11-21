import Foundation
#if canImport(Combine)
import Combine
#endif

/// What Settings, the Screen section and the pet menu show about screen capture.
@MainActor
package final class CaptureStatusModel {
    package init() {}

    /// Fires before any of these change.
    package let changes = ChangeSignal()
    package var running = false { willSet { changes.send() } }
    package var accessibility = true { willSet { changes.send() } }
    package var screenRecording = false { willSet { changes.send() } }
    package var paused = false { willSet { changes.send() } }
    package var pausedUntil: Date? { willSet { changes.send() } }
    package var captureCount = 0 { willSet { changes.send() } }
    package var lastCapture: Date? { willSet { changes.send() } }
    package var lastSkip: String? { willSet { changes.send() } }
}

#if canImport(Combine)
extension CaptureStatusModel: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
