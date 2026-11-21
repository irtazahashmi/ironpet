import Foundation
#if canImport(Combine)
import Combine

/// SwiftUI observes the chat through `ObservableObject`. The signal sends on its publisher before the chat's values change.
extension ChatSession: ObservableObject {
    nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
