import CryptoKit
import IronPetKit
import SwiftUI

@main
struct IronPetRemoteApp: App {
    @State private var model: AppModel

    init() {
        let store = KeychainCredentialStore()
        #if DEBUG
        // UI tests start from an unpaired app.
        if ProcessInfo.processInfo.arguments.contains("--reset-credentials") {
            store.delete()
        }
        #endif
        _model = State(initialValue: AppModel(store: store))
    }

    /// UI tests launch in dark mode with `--force-dark`, because the simulator's own appearance switch does not apply on every runner.
    private static var forcedScheme: ColorScheme? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--force-dark") ? .dark : nil
        #else
        nil
        #endif
    }

    var body: some Scene {
        WindowGroup { RootView(model: model).preferredColorScheme(Self.forcedScheme) }
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .unpaired:
            PairingView(model: model)
                .sheet(item: Binding(get: { model.problem }, set: { model.problem = $0 })) { problem in
                    ProblemSheet(problem: problem) { model.problem = nil }
                }
        case .paired(let device):
            // A new token means a new client and a new socket, so the identity follows the token.
            MainTabs(model: model, device: device).id(device.token)
        }
    }
}

struct MainTabs: View {
    let model: AppModel
    @State private var tab: AppTab = .pet
    @Environment(\.scenePhase) private var scenePhase
    @State private var network: NetworkHealth
    @State private var inbox: InboxModel
    @State private var pet: PetModel
    @State private var chat: ChatModel
    @State private var chats: AgentChatsModel
    @State private var today: TodayModel
    @State private var agents: AgentsModel
    @State private var alerts: AlertsModel
    @State private var automations: AutomationsModel
    @State private var meetings: MeetingsModel
    @State private var meetingUploads: MeetingUploadsModel
    @State private var memory: MemoryModel
    @State private var screen: ScreenModel
    @State private var phoneSettings: PhoneSettingsModel
    @State private var phoneAgent: PhoneAgentModel
    @State private var dashboards: DashboardsModel
    @State private var voice: VoiceModel
    @State private var morePath: [MoreDestination] = []
    private let client: IronPetClient
    private let events: SharedEventSource

    init(model: AppModel, device: PairedDevice) {
        self.model = model
        let client = IronPetClient(endpoint: device.endpoint, token: device.token)
        self.client = client
        // The Mac allows three sockets per device and five screens want events, so they share one.
        // The last event seq survives a restart of the app, so the first connection after a launch can resume too.
        let connection = EventConnection(client: client, store: DefaultsResumeStore(key: DefaultsResumeStore.keyPrefix + SHA256.hash(data: Data((client.token ?? "").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()))
        let events = SharedEventSource(connection)
        self.events = events
        let unauthorized: () -> Void = { [weak model] in model?.handleUnauthorized() }
        let network = Self.makeNetwork()
        network.onPathReturned = { [events] in events.reconnectNow() }
        _network = State(initialValue: network)
        _inbox = State(initialValue: InboxModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _pet = State(initialValue: PetModel(client: client, events: events, cache: AssetCache(directory: Self.assetsDirectory), network: network, onUnauthorized: unauthorized))
        let chatModel = ChatModel(client: client, events: events, network: network, onUnauthorized: unauthorized)
        // Typed messages go over the same socket the events arrive on.
        chatModel.socket = connection
        // Messages typed without a connection wait in a file in the app's own container until the Mac is back.
        chatModel.useOutbox(FileOutboxStore.forToken(client.token))
        // The chat the phone saw last shows at once, before the Mac answers.
        chatModel.useCache(FileChatCache.forToken(client.token))
        _chat = State(initialValue: chatModel)
        // One chat model per other agent, each with its own cache file. Their messages wait in memory, not in the outbox file.
        let agentChats = AgentChatsModel(client: client, events: events, network: network, main: chatModel, makeChat: { [client] agentId in
            let model = ChatModel(client: client, events: events, network: network, agentId: agentId, onUnauthorized: unauthorized)
            model.useCache(FileChatCache.forToken(client.token, agentId: agentId))
            return model
        }, onUnauthorized: unauthorized)
        _chats = State(initialValue: agentChats)
        _today = State(initialValue: TodayModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _agents = State(initialValue: AgentsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _memory = State(initialValue: MemoryModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _alerts = State(initialValue: AlertsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _automations = State(initialValue: AutomationsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _meetings = State(initialValue: MeetingsModel(client: client, events: events, gate: TranscriptGate(authenticator: Self.authenticator), network: network, onUnauthorized: unauthorized))
        let uploads = MeetingUploadsModel(queue: MeetingUploadsModel.defaultQueue(), transport: client)
        _meetingUploads = State(initialValue: uploads)
        _screen = State(initialValue: ScreenModel(client: client, events: events, gate: TranscriptGate(authenticator: Self.authenticator, reason: "Show screen text"),
                                                  network: network, onUnauthorized: unauthorized))
        _phoneSettings = State(initialValue: PhoneSettingsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _phoneAgent = State(initialValue: PhoneAgentModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _dashboards = State(initialValue: DashboardsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _voice = State(initialValue: Self.makeVoice(client: client))
    }

    /// Files that wait for the Mac (shared from another app while this one was closed) go out as soon as the tabs show, and again
    /// whenever the connection comes back.
    private func startMeetingUploads() {
        meetingUploads.onConfirmed = { [meetings] in await meetings.refresh() }
        meetingUploads.kick()
        let reconnects = network.reconnects()
        Task { [meetingUploads] in
            for await _ in reconnects { meetingUploads.retryNow() }
        }
    }

    /// The model of one dashboard that is opened. A tap that sent the pet a prompt switches to the Chat tab.
    private func makeDashboardModel(_ id: String) -> DashboardViewModel {
        let viewModel = DashboardViewModel(id: id, client: client, events: events, network: network, onUnauthorized: { [weak app = self.model] in app?.handleUnauthorized() })
        viewModel.openChat = { tab = .chat }
        viewModel.openLink = { UIApplication.shared.open($0) }
        return viewModel
    }

    /// UI tests shorten the wait before the strip shows (`--network-strip-delay 2`) and the wait between tries (`--network-retry-ms 100`).
    private static func makeNetwork() -> NetworkHealth {
        let network = NetworkHealth()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> Double? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } }
        if let seconds = value("--network-strip-delay") { network.stripDelay = .milliseconds(Int(seconds * 1000)) }
        if let millis = value("--network-retry-ms") { network.retryPolicy = RetryPolicy(attempts: 3, base: .milliseconds(Int(millis)), maxDelay: .milliseconds(Int(millis) * 4)) }
        #endif
        return network
    }

    private static func makeVoice(client: IronPetClient) -> VoiceModel {
        #if DEBUG
        if DebugVoice.enabled {
            return VoiceModel(player: ReplyPlayer(engine: AudioPlayerEngine()), openChannel: { SilentVoiceChannel() }, makeMic: { PulseMicSource() })
        }
        #endif
        return VoiceModel(player: ReplyPlayer(engine: AudioPlayerEngine()), openChannel: { client.openVoiceChannel() }, makeMic: { EngineMicSource() })
    }

    /// Face ID or the passcode. UI tests launch with `--auto-unlock`, because a simulator cannot answer the system prompt.
    private static var authenticator: any DeviceAuthenticating {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--auto-unlock") { return AlwaysAllow() }
        #endif
        return LocalAuthenticator()
    }

    /// `Application Support/assets`, where files live under their hash.
    static var assetsDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("assets", isDirectory: true)
    }

    /// Whether the Mac tracks coding agents. Off removes the Agents tab. Reads as on until the Mac has answered.
    private var tracksAgents: Bool { phoneSettings.config?.agents.trackAgents ?? true }

    var body: some View {
        TabView(selection: $tab) {
            PetView(model: pet, today: today, app: model, client: client, open: open)
                .tabItem { Label("Pet", systemImage: AppTab.pet.symbol) }.tag(AppTab.pet)
            ChatView(model: chats.current, backgroundID: pet.backgroundID, backgroundImage: pet.backgroundImage,
                     avatar: chats.currentRecord.map { $0.isDefault } ?? true ? PetAvatar.face(of: pet.atlas) : nil,
                     petName: chats.currentRecord.flatMap { $0.isDefault ? nil : $0.displayName } ?? pet.pet?.name ?? "", agents: chats)
                .id(chats.current.agentId ?? defaultAgentID)
                .tabItem { Label("Chat", systemImage: AppTab.chat.symbol) }.badge(chats.waitingCount).tag(AppTab.chat)
            InboxView(model: inbox, onShowChat: { tab = .chat })
                .tabItem { Label("Inbox", systemImage: AppTab.tasks.symbol) }.tag(AppTab.tasks)
            if tracksAgents {
                AgentsView(model: agents)
                    .tabItem { Label("Agents", systemImage: AppTab.agents.symbol) }.tag(AppTab.agents)
            }
            MoreView(dashboards: dashboards, makeDashboard: makeDashboardModel, alerts: alerts, automations: automations, meetings: meetings, uploads: meetingUploads, memory: memory, screen: screen, settings: phoneSettings, phoneAgent: phoneAgent, path: $morePath)
                .tabItem { Label("More", systemImage: AppTab.more.symbol) }.badge(alerts.alerts.count + automations.automations.filter(\.waitsForApproval).count + dashboards.badge)
                .tag(AppTab.more)
        }
        .themedTabBar()
        .networkStatusStrip(network)
        .sheet(item: Binding(get: { network.problem }, set: { network.problem = $0 })) { problem in
            ProblemSheet(problem: problem) { network.problem = nil }
        }
        .environment(\.macBackground, MacBackground(id: pet.backgroundID, image: pet.backgroundImage))
        .environment(voice)
        // The Mac's accent colour, when it has one. `nil` leaves the app's own tint, the system blue.
        .tint(pet.accent)
        .environment(\.macAccent, pet.accent ?? .accentColor)
        // The alert count and the waiting approvals are on their tabs before the user opens it.
        .task { network.startPathMonitor(); phoneSettings.start(); alerts.start(); dashboards.start(); chat.start(); chats.start(); pet.start(); automations.start(); phoneAgent.start(); startMeetingUploads(); voice.onTranscript = { [chat] text, mode in if mode == .draft { chat.insertDictation(text) } }; voice.onSend = { [chat] in chat.voiceEvent($0) }; chat.resendVoice = { [voice] in await voice.resend($0) }; chat.transcribeSaved = { [voice] in await voice.transcribeSaved($0, $1) }; voice.hasComposerContent = { [chat] in chat.hasComposerContent }; voice.hasEarlierMessages = { [chat] in chat.hasEarlierMessages }; voice.start(); VoiceLaunch.shared.handler = { [voice] in await voice.startVoiceMode() } }
        // The five minutes count from the app going to the background, whichever screen is open. Watching only inside the Meetings
        // screen would leave the text unlocked after the person left it and then left the app.
        .onChange(of: scenePhase) { _, phase in
            // The socket was dropped in the background. Reconnect now instead of after the back-off.
            if phase == .active { events.reconnectNow(); meetingUploads.retryNow() }
            meetings.gate.scenePhaseChanged(phase)
            screen.gate.scenePhaseChanged(phase)
        }
        // The tab bar loses Agents when the Mac turns tracking off; leave the tab first so the selection never points at nothing.
        .onChange(of: tracksAgents) { _, tracks in if !tracks, tab == .agents { tab = .pet } }
        // A background changed on the Mac shows when the Chat tab opens.
        .onChange(of: tab) { _, next in if next == .chat { Task { await pet.reloadPet(applyMood: false); await chats.refresh() } } }
        // Leaving the tabs (unpair or a 401) must close the socket, which otherwise keeps reconnecting with the old token.
        .onDisappear { [network, inbox, pet, chat, chats, today, agents, alerts, automations, meetings, meetingUploads, memory, screen, phoneSettings, phoneAgent, dashboards, voice] in
            meetingUploads.stop()
            voice.stop()
            VoiceLaunch.shared.handler = nil
            network.stopPathMonitor()
            inbox.stop(); pet.stop(); chat.stop(); chats.stop(); today.stop(); agents.stop(); alerts.stop(); automations.stop(); meetings.stop(); memory.stop(); screen.stop(); phoneSettings.stop(); phoneAgent.stop(); dashboards.stop()
            meetings.gate.lock()
            screen.gate.lock()
        }
    }

    /// A Today item opens the tab that holds its target. A session opens its detail.
    private func open(_ target: TodayTarget) {
        guard let next = AppTab.tab(for: target), next != .agents || tracksAgents else { return }
        if target.type == .session { agents.pendingDetail = target.id }
        if let destination = MoreDestination.destination(for: target) { morePath = [destination] }
        tab = next
    }
}

#if DEBUG
/// Stands in for the system prompt in UI tests only.
struct AlwaysAllow: DeviceAuthenticating {
    func authenticate(reason: String) async -> Bool { true }
}
#endif
