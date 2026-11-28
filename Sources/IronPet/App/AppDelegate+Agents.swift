import AppKit
import IronPetCore

/// Several agents at once: the supervisor that runs one chat process per enabled agent, the pets of the agents other than agent 1, and
/// each other agent's chat. Agent 1 is the chat, pet and window the app always had.
extension AppDelegate {
    /// Starts the supervisor and the extra pets. Called once, after the automations exist, since an agent's chat reports its automations.
    func setUpAgents() {
        guard let registry = api.agentRecords?.registry else { return }
        chatModel.agentRecords = { registry.list() }
        chatModel.onPickAgent = { [weak self] id in self?.openAgentChat(id) }
        // Voice and speech follow the active agent: its chat gets the transcript and only it reads its replies aloud.
        let router = VoiceTranscriptRouter(activeAgent: { [weak self] in self?.api.chats.activeAgentID ?? AgentOwner.defaultID },
                                           model: { [weak self] id in id == AgentOwner.defaultID ? self?.chatModel : self?.agentPets?.pets[id]?.chat })
        chatModel.voice.onTranscript = { router.route($0) }
        spokenMessages.send = { router.routeSpoken($0) }
        chat.speaksReplies = { [weak self] in self?.api.chats.speaksReplies(AgentOwner.defaultID) ?? true }
        pet.onSelected = { [weak self] in self?.selectAgent(AgentOwner.defaultID) }
        activeAgentToken = registry.activeChanges.observe { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshActiveHighlight() } }
        }
        api.chats.makeSession = { [weak self] id in
            guard let self else { return ChatSession(restore: true, agentID: id) }
            return self.makeAgentSession(id)
        }
        api.chats.onStopped = { [weak self] id in self?.agentStopped(id) }
        let pets = AgentPets(api: api, registry: registry, events: events) { [weak self] slot, session, model in
            self!.makeAgentPet(slot, session, model)
        }
        pets.onChanged = { [weak self] in self?.refreshActiveHighlight() }
        agentPets = pets
        let supervisor = AgentSupervisor(registry: registry, launcher: api.chats)
        self.supervisor = supervisor
        supervisor.reconcile()
        pets.start()
    }

    /// The chat of an agent other than agent 1, with the callbacks agent 1's chat has: a bubble for an approval, a question or a finished
    /// task, each naming the agent, and its automations' notices and replies.
    private func makeAgentSession(_ id: String) -> ChatSession {
        let session = ChatSession(restore: true, speech: chat.speech, agentID: id)
        session.speaksReplies = { [weak self] in self?.api.chats.speaksReplies(id) ?? true }
        session.spawner = platform.processes
        session.onSpokenTurnEnded = { [weak self] failed in self?.spokenMessages.turnEnded(failed: failed) }
        session.onAttention = { [weak self, weak session] title in
            guard let session else { return }
            self?.announcer.chat("\(session.agentDisplayName): \(title)")
        }
        session.onApprovalNeeded = { [weak self, weak session] approval in
            self?.announcer.approval(id: approval.id, title: approval.title, detail: approval.detail, agentName: session?.agentDisplayName)
        }
        session.onFormNeeded = { [weak self] title, detail in self?.announcer.chat(title, detail: detail) }
        session.onApprovalResolved = { [weak self] approval in self?.announcer.clearApproval(id: approval) }
        agentSessionTokens[id] = session.changes.observe { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.agentPets?.refreshMoods() } }
        }
        if let service = automations {
            session.onAutomation = { [weak service] automation, event in service?.chatOutcome(automation, event) }
            service.agentChats[id] = .init(
                postNotice: { [weak session] kind, title, text, triggers in session?.postSystemNotice(kind: kind, text: text, title: title, triggersTurn: triggers) },
                sendToChat: { [weak session] automation, message in session?.submitFromAutomation(message, automation: automation) ?? false },
                chatRunPending: { [weak session] automation in session?.hasAutomationRun(automation) ?? false },
                forkSource: { [weak session] automation in
                    guard let session, session.agent.id == AutomationPrompt.agentID(automation) else { return nil }
                    return session.sessionID
                })
        }
        return session
    }

    private func agentStopped(_ id: String) {
        agentSessionTokens[id] = nil
        automations?.agentChats[id] = nil
    }

    /// The pet of another agent: its own sprite and place, its own chat window, and the sections every pet's window shows.
    private func makeAgentPet(_ slot: PetSlot, _ session: ChatSession, _ model: ChatViewModel) -> PetController {
        let controller = PetController(store: store, signals: signals, agentID: slot.agentID, sprite: slot.sprite, offsetX: slot.offsetX)
        model.agentRecords = { [weak self] in self?.api.agentRecords?.registry.list() ?? [] }
        model.onPickAgent = { [weak self] id in self?.openAgentChat(id) }
        controller.onSelected = { [weak self] in self?.selectAgent(slot.agentID) }
        controller.chat = session
        controller.chatModel = model
        controller.tasks = api.tasks
        controller.alerts = api.alerts
        controller.agents = api.agents
        controller.meetingsAPI = api.meetings
        controller.notifications = pet.notifications
        controller.settings = settingsModel
        controller.brief = pet.brief
        controller.chatMood = { [weak session] in session?.mood }
        controller.onAsk = { [weak self] prompt in self?.ask(prompt) }
        controller.onSay = { [weak self] text in self?.announcer.say(text) }
        controller.onTellGhost = { [weak self] text in self?.sendToChat(text, show: true, title: "Tasks", busyBody: "Send it to the chat?") }
        controller.onOpenThread = { [weak self] id in
            guard let self, let thread = ThreadStore.load(id) else { return }
            if thread.ownerAgentID == AgentOwner.defaultID { chat.open(thread); showChat() } else { session.open(thread) }
        }
        controller.onOpenSession = { [weak self] id in self?.openSession(id) }
        controller.onOpenJob = { [weak self] id in self?.openJob(id) }
        controller.extraMenuItems = { [weak self] in self?.hookMenuItems() ?? [] }
        controller.onSettings = { [weak self] in self?.showSettings(tab: nil) }
        controller.onScreenSettings = { [weak self] in self?.showSettings(tab: "screen") }
        controller.onMemorySettings = { [weak self] in self?.showSettings(tab: "memory") }
        controller.onChatShown = { [weak session, weak controller] shown in
            guard let session else { return }
            if shown {
                session.prepareForShow()
                session.isVisible = true
                controller?.window.focusInput()
            } else {
                session.isVisible = false
            }
            controller?.refreshMood()
        }
        controller.onChatToggle = { [weak controller] in
            guard let controller else { return }
            if controller.isChatVisible { controller.closeWindow() } else {
                controller.showWindow(.chat)
            }
        }
        return controller
    }

    /// Makes an agent the active one. An agent that is gone or disabled changes nothing.
    func selectAgent(_ id: String) {
        try? api.chats.select(active: id)
    }

    /// Puts the highlight on the active agent's pet, and on no pet while there is only one.
    func refreshActiveHighlight() {
        let onScreen = [AgentOwner.defaultID] + (agentPets?.pets.keys.sorted() ?? [])
        let lit = AgentPetSet.highlighted(active: api.chats.activeAgentID, onScreen: onScreen)
        pet.isHighlighted = lit == AgentOwner.defaultID
        for (id, other) in agentPets?.pets ?? [:] { other.controller.isHighlighted = lit == id }
    }

    /// Opens the active agent's chat without changing which agent is active, for the voice shortcut.
    func showActiveChat() {
        let id = api.chats.activeAgentID
        if id == AgentOwner.defaultID {
            showChat()
        } else if let controller = agentPets?.pets[id]?.controller, !controller.isChatVisible {
            controller.showWindow(.chat)
        }
    }

    /// Opens an agent's chat: agent 1's in the main window, any other agent's in the window of its own pet. The agent becomes the active one.
    func openAgentChat(_ id: String) {
        selectAgent(id)
        if id == AgentOwner.defaultID {
            showChat()
        } else if let pets = agentPets?.pets[id] {
            pets.controller.onChatToggle?()
        }
    }
}
