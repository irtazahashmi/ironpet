import Foundation
import IronPetCore

/// The Mac speaker for a conversation is the speech player.
extension SpeechPlayer: ConversationSpeaker {}

extension VoiceConversation {
    /// Listens through `ConversationMic`, speaks through a `SpeechPlayer` on the microphone's engine, and asks the system for
    /// microphone access. A conversation starts without them, so a client that is not this Mac gets `Unsupported` ones.
    func useMacAudio() {
        microphoneAllowed = { await VoiceController.microphoneAllowed() }
        makeMic = { ConversationMic() }
        makeSpeaker = { [weak self] mic in
            let player = SpeechPlayer(player: mic?.player)
            player.isEnabled = { true }
            player.voiceKey = self?.voiceKey ?? .unsupported
            return player
        }
    }
}
