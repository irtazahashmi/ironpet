import IronPetCore

/// Sends a voice note's transcript to the chat of the active agent, the pet the user selected last. The hotkey records once, on one
/// recorder, so this decides where the text goes. An agent with no chat on screen falls back to agent 1's.
@MainActor
struct VoiceTranscriptRouter {
    /// The agent the transcript goes to.
    let activeAgent: () -> String
    /// The chat view model of an agent, nil when that agent has no chat on screen.
    let model: (String) -> ChatViewModel?

    /// The agent whose chat receives the next transcript.
    var target: String {
        let id = activeAgent()
        return model(id) == nil ? AgentOwner.defaultID : id
    }

    func route(_ text: String) {
        model(target)?.receiveTranscript(text)
    }
}
