import Foundation
import IronPetKit
import Observation

/// The agent on this phone: its conversation, its settings, its queue of inbox items and its registration with the Mac. It reads the event
/// socket like every tab model, so a reconnect sends the waiting items and registers the agent.
@MainActor @Observable
final class PhoneAgentModel: SocketModel {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, tool, error }
        let id = UUID()
        var role: Role
        var text: String
    }

    enum Registration: Equatable {
        /// No key is set, so the phone has no agent to register.
        case notConfigured
        /// The Mac did not take the registration yet. It is tried again when the Mac answers.
        case pending(String)
        case registered(RemoteAgentRecord)
    }

    private(set) var messages: [Message] = []
    private(set) var isRunning = false
    private(set) var registration: Registration = .notConfigured
    /// Items the agent added that the Mac has not taken yet.
    private(set) var waiting: [QueuedInboxItem] = []
    private(set) var config: AgentConfig
    private(set) var hasKey: Bool

    static let agentName = "Ghost on iPhone"

    @ObservationIgnored let inbox: PhoneInbox
    @ObservationIgnored private let keys: any AgentKeyStoring
    @ObservationIgnored private let settings: PhoneAgentSettings
    @ObservationIgnored private let transport: any AgentTransport
    @ObservationIgnored private let fetcher: any WebFetching
    @ObservationIgnored private let calendar: any DeviceCalendarHost
    @ObservationIgnored private var history: [AgentTurn] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(client: IronPetClient, events: any EventSignalSource, network: NetworkHealth? = nil, keys: any AgentKeyStoring = KeychainAgentKeyStore(),
         settings: PhoneAgentSettings = PhoneAgentSettings(), queue: any InboxQueueStoring = FileInboxQueueStore(),
         transport: any AgentTransport = URLSessionAgentTransport(), fetcher: any WebFetching = URLSessionWebFetcher(),
         calendar: any DeviceCalendarHost = EventKitCalendar(), onUnauthorized: @escaping () -> Void) {
        self.keys = keys
        self.settings = settings
        self.transport = transport
        self.fetcher = fetcher
        self.calendar = calendar
        let config = settings.config
        self.config = config
        hasKey = keys.hasKey(for: config.provider)
        inbox = PhoneInbox(store: queue, remote: ClientInboxRemote(client))
        super.init(client: client, events: events, network: network, onUnauthorized: onUnauthorized)
        if hasKey { registration = .pending("Waiting for the Mac") }
        Task { await self.updateWaiting() }
    }

    // MARK: Settings

    /// Saves provider, model and key. An empty key keeps the one in the Keychain. The Mac learns about the agent when it answers.
    func save(provider: AgentProvider, model: String, key: String) async throws {
        let saved = AgentConfig(provider: provider, model: model)
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try keys.setKey(key, for: provider) }
        settings.config = saved
        config = saved
        hasKey = keys.hasKey(for: provider)
        await syncWithMac()
    }

    func removeKey() {
        keys.removeKey(for: config.provider)
        hasKey = false
        registration = .notConfigured
    }

    // MARK: Mac

    override func reload() async { await syncWithMac() }

    /// Sends the waiting items and registers the agent. Both are safe to repeat.
    func syncWithMac() async {
        guard hasKey else { registration = .notConfigured; await updateWaiting(); return }
        _ = await inbox.flush()
        await updateWaiting()
        do {
            let record = try await client.registerPhoneAgent(name: Self.agentName, provider: config.provider, model: config.model)
            registration = .registered(record)
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch ClientError.api(let status, _, _) where status == 404 || status == 405 {
            registration = .pending("This Mac is too old to list the phone's agent. Update IronPet on the Mac.")
        } catch {
            registration = .pending("Waiting for the Mac")
        }
    }

    private func updateWaiting() async { waiting = await inbox.pending }

    // MARK: Conversation

    func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isRunning else { return }
        guard hasKey else {
            messages.append(Message(role: .error, text: "Add your \(config.provider.label) API key in the agent's settings first."))
            return
        }
        messages.append(Message(role: .user, text: message))
        messages.append(Message(role: .assistant, text: ""))
        isRunning = true
        let config = config
        let history = history
        task = Task { [weak self] in
            guard let self else { return }
            let loop = self.makeLoop()
            do {
                let added = try await loop.run(message, history: history, config: config) { event in
                    Task { @MainActor [weak self] in self?.apply(event) }
                }
                self.history = history + added
            } catch is CancellationError {
            } catch {
                self.messages.append(Message(role: .error, text: error.localizedDescription))
            }
            self.dropEmptyAssistantRow()
            self.isRunning = false
            await self.updateWaiting()
        }
    }

    func cancelRun() { task?.cancel() }

    func newConversation() {
        task?.cancel()
        history = []
        messages = []
    }

    private func makeLoop() -> AgentLoop {
        let tools: [any AgentTool] = InboxTools.all(inbox) + MemoryTools.all(ClientMemoryHost(client)) + [DateTimeTool(), WebFetchTool(fetcher)]
            + CalendarTools.all(calendar) + [PhoneAgentSkills.LoadTool(PhoneAgentSkills.bundled)]
        return AgentLoop(transport: transport, keys: keys, tools: tools, system: PhoneAgentPrompt.system(skills: PhoneAgentSkills.bundled))
    }

    private func apply(_ event: AgentLoopEvent) {
        switch event {
        case .text(let piece):
            if messages.last?.role == .assistant { messages[messages.count - 1].text += piece } else { messages.append(Message(role: .assistant, text: piece)) }
        case .toolStarted(let name):
            dropEmptyAssistantRow()
            messages.append(Message(role: .tool, text: Self.toolLabel(name)))
        case .toolFinished:
            messages.append(Message(role: .assistant, text: ""))
        }
    }

    private func dropEmptyAssistantRow() {
        while let last = messages.last, last.role == .assistant, last.text.isEmpty { messages.removeLast() }
    }

    static func toolLabel(_ name: String) -> String {
        switch name {
        case "inbox_add": return "Adding to the inbox"
        case "inbox_list": return "Reading the inbox"
        case "inbox_done", "inbox_remove": return "Updating the inbox"
        case "memory_search", "memory_read": return "Reading memory"
        case "calendar_events": return "Reading the calendar"
        case "reminder_add": return "Adding a reminder"
        case "web_fetch": return "Reading a web page"
        case "load_skill": return "Loading a skill"
        default: return "Working"
        }
    }
}
