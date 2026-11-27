import Foundation
import IronPetKit

/// What the microphone reports while a spoken message is recorded.
package enum ConversationMicEvent: Equatable {
    case speechStarted
    /// One utterance as a 16 kHz mono WAV.
    case utterance(Data)
    /// Something too short to be speech ended.
    case discarded
    case failed(String)
}

/// What `SpokenMessageRecorder` needs from the microphone. `ConversationMic` is the Mac one; tests send events by hand.
@MainActor
package protocol ConversationListening: AnyObject {
    var onEvent: ((ConversationMicEvent) -> Void)? { get set }
    var levels: LevelBuffer { get }
    /// Throws `CapabilityError.unsupported` where nothing can listen.
    func start() throws
    func stop()
    /// Ends the utterance in progress now, as if the user had stopped talking. Reports it as `utterance`, or as `discarded`
    /// when nothing was said.
    func cutNow()
}

/// Hears nothing.
@MainActor
package final class UnsupportedConversationMic: ConversationListening {
    package var platform = PlatformName.current
    package var onEvent: ((ConversationMicEvent) -> Void)?
    package let levels = LevelBuffer()

    package init() {}

    package func start() throws { throw CapabilityError.unsupported(capability: "ConversationListening", platform: platform) }
    package func stop() {}
    package func cutNow() {}
}
