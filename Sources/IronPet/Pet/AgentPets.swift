import AppKit
import IronPetCore

/// The pets of the agents other than agent 1, one for each enabled agent whose process the supervisor runs. Agent 1's pet is the one the
/// app always had. This follows the agent registry and the chats the supervisor started: an agent that is enabled and running gets a pet
/// and a chat window, and one that is disabled or deleted loses both. Its threads stay on disk.
@MainActor
final class AgentPets {
    struct Pet {
        let controller: PetController
        let chat: ChatViewModel
        let session: ChatSession
        var slot: PetSlot
    }

    private let api: IronPetAPI
    private let registry: AgentRegistry
    /// Builds the pet for a slot over that agent's chat. The app fills in the stores, callbacks and sections the pet shares with agent 1's.
    private let make: (PetSlot, ChatSession, ChatViewModel) -> PetController
    private let events: APIEventBus
    private(set) var pets: [String: Pet] = [:]
    private var tokens: [ChangeToken] = []
    private var syncPending = false
    /// Called after the pets on screen changed, so the app can move the active highlight.
    var onChanged: (() -> Void)?

    init(api: IronPetAPI, registry: AgentRegistry, events: APIEventBus, make: @escaping (PetSlot, ChatSession, ChatViewModel) -> PetController) {
        self.api = api
        self.registry = registry
        self.events = events
        self.make = make
    }

    /// Starts following the registry and the supervisor's chats.
    func start() {
        tokens = [registry.changes.observe { [weak self] in self?.scheduleSync() }, api.chats.changes.observe { [weak self] in self?.scheduleSync() }]
        sync()
    }

    func stop() {
        tokens = []
        for id in Array(pets.keys) { remove(id) }
    }

    /// Both signals fire before the change, so the pets are read again on the next main-actor turn.
    private func scheduleSync() {
        guard !syncPending else { return }
        syncPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.syncPending = false
                self?.sync()
            }
        }
    }

    /// Makes the pets on screen match the agents that are enabled and running.
    func sync() {
        let running = Set(api.chats.runningAgents)
        let wanted = AgentPetSet.slots(for: registry.list()).filter { $0.agentID != AgentOwner.defaultID && running.contains($0.agentID) }
        for id in Array(pets.keys) where !wanted.contains(where: { $0.agentID == id }) { remove(id) }
        for slot in wanted {
            guard let session = api.chats.session(for: slot.agentID), let chat = try? api.chats.api(for: slot.agentID) else { continue }
            if var existing = pets[slot.agentID] {
                // A pet is rebuilt when the chat behind it was replaced by a restart, and updated in place for a new name or sprite.
                if existing.session !== session {
                    remove(slot.agentID)
                } else {
                    if existing.slot != slot {
                        existing.controller.agentName = slot.name
                        existing.chat.agentName = slot.name
                        if existing.slot.sprite != slot.sprite {
                            existing.controller.reloadAtlas(sprite: slot.sprite)
                            existing.chat.avatar = AvatarSprite(path: slot.sprite)
                        }
                        existing.slot = slot
                        pets[slot.agentID] = existing
                    }
                    continue
                }
            }
            let model = ChatViewModel(api: chat, voiceAPI: api.voice, events: events, persists: false)
            model.agentName = slot.name
            model.avatar = AvatarSprite(path: slot.sprite)
            let controller = make(slot, session, model)
            controller.agentName = slot.name
            pets[slot.agentID] = Pet(controller: controller, chat: model, session: session, slot: slot)
            controller.show()
        }
        onChanged?()
    }

    private func remove(_ id: String) {
        guard let pet = pets.removeValue(forKey: id) else { return }
        pet.controller.closeWindow()
        pet.controller.panel.orderOut(nil)
        pet.session.isVisible = false
    }

    /// Opens an agent's chat window next to its pet. Agent 1's is the app's own, which the caller opens.
    func open(_ agentID: String) {
        pets[agentID]?.controller.handleClick()
    }

    /// The pet's mood follows its chat, so a pet that waits for an answer shows it.
    func refreshMoods() {
        for pet in pets.values { pet.controller.refreshMood() }
    }
}
