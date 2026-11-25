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
            UserDefaults.standard.removeObject(forKey: TasksViewMode.key)
            UserDefaults.standard.removeObject(forKey: QuickFilterSelection.key)
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
    @State private var tasks: TasksModel
    @State private var pet: PetModel
    @State private var chat: ChatModel
    @State private var today: TodayModel
    @State private var agents: AgentsModel
    @State private var alerts: AlertsModel
    @State private var automations: AutomationsModel
    @State private var meetings: MeetingsModel
    @State private var memory: MemoryModel
    @State private var screen: ScreenModel
    @State private var phoneSettings: PhoneSettingsModel
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
        _network = State(initialValue: network)
        // The last task list and the changes made offline live in a file in the app's own container, one per pairing.
        let tasksModel = TasksModel(client: client, events: events, store: FileTaskSyncStore.forToken(client.token), network: network, onUnauthorized: unauthorized)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--pending-sync-all") { tasksModel.debugAllPending = true }
        #endif
        _tasks = State(initialValue: tasksModel)
        _pet = State(initialValue: PetModel(client: client, events: events, cache: AssetCache(directory: Self.assetsDirectory), network: network, onUnauthorized: unauthorized))
        let chatModel = ChatModel(client: client, events: events, network: network, onUnauthorized: unauthorized)
        // Typed messages go over the same socket the events arrive on.
        chatModel.socket = connection
        // Messages typed without a connection wait in a file in the app's own container until the Mac is back.
        chatModel.useOutbox(FileOutboxStore.forToken(client.token))
        // The chat the phone saw last shows at once, before the Mac answers.
        chatModel.useCache(FileChatCache.forToken(client.token))
        _chat = State(initialValue: chatModel)
        _today = State(initialValue: TodayModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _agents = State(initialValue: AgentsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _memory = State(initialValue: MemoryModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _alerts = State(initialValue: AlertsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _automations = State(initialValue: AutomationsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _meetings = State(initialValue: MeetingsModel(client: client, events: events, gate: TranscriptGate(authenticator: Self.authenticator), network: network, onUnauthorized: unauthorized))
        _screen = State(initialValue: ScreenModel(client: client, events: events, gate: TranscriptGate(authenticator: Self.authenticator, reason: "Show screen text"),
                                                  network: network, onUnauthorized: unauthorized))
        _phoneSettings = State(initialValue: PhoneSettingsModel(client: client, events: events, network: network, onUnauthorized: unauthorized))
        _voice = State(initialValue: Self.makeVoice(client: client))
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

    var body: some View {
        TabView(selection: $tab) {
            PetView(model: pet, today: today, app: model, client: client, open: open)
                .tabItem { Label("Pet", systemImage: AppTab.pet.symbol) }.tag(AppTab.pet)
            ChatView(model: chat, backgroundID: pet.backgroundID, backgroundImage: pet.backgroundImage, avatar: PetAvatar.face(of: pet.atlas), petName: pet.pet?.name ?? "")
                .tabItem { Label("Chat", systemImage: AppTab.chat.symbol) }.badge(chat.approvals.count + chat.forms.count).tag(AppTab.chat)
            TasksView(model: tasks, onAsk: { [chat] text in
                tab = .chat
                Task { await chat.sendPrompt(text) }
            })
                .tabItem { Label("Tasks", systemImage: AppTab.tasks.symbol) }.tag(AppTab.tasks)
            AgentsView(model: agents)
                .tabItem { Label("Agents", systemImage: AppTab.agents.symbol) }.tag(AppTab.agents)
            MoreView(alerts: alerts, automations: automations, meetings: meetings, memory: memory, screen: screen, settings: phoneSettings, path: $morePath)
                .tabItem { Label("More", systemImage: AppTab.more.symbol) }.badge(alerts.alerts.count + automations.automations.filter(\.waitsForApproval).count)
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
        .task { network.startPathMonitor(); alerts.start(); chat.start(); pet.start(); automations.start(); voice.onTranscript = { [chat] text, mode in if mode == .draft { chat.insertDictation(text) } }; voice.onSend = { [chat] in chat.voiceEvent($0) }; chat.resendVoice = { [voice] in await voice.resend($0) }; chat.transcribeSaved = { [voice] in await voice.transcribeSaved($0, $1) }; voice.hasComposerContent = { [chat] in chat.hasComposerContent }; voice.hasEarlierMessages = { [chat] in chat.hasEarlierMessages }; voice.start() }
        // The five minutes count from the app going to the background, whichever screen is open. Watching only inside the Meetings
        // screen would leave the text unlocked after the person left it and then left the app.
        .onChange(of: scenePhase) { _, phase in
            // The socket was dropped in the background. Reconnect now instead of after the back-off.
            if phase == .active { events.reconnectNow() }
            meetings.gate.scenePhaseChanged(phase)
            screen.gate.scenePhaseChanged(phase)
        }
        // A background changed on the Mac shows when the Chat tab opens.
        .onChange(of: tab) { _, next in if next == .chat { Task { await pet.reloadPet(applyMood: false) } } }
        // Leaving the tabs (unpair or a 401) must close the socket, which otherwise keeps reconnecting with the old token.
        .onDisappear { [network, tasks, pet, chat, today, agents, alerts, automations, meetings, memory, screen, phoneSettings, voice] in
            voice.stop()
            network.stopPathMonitor()
            tasks.stop(); pet.stop(); chat.stop(); today.stop(); agents.stop(); alerts.stop(); automations.stop(); meetings.stop(); memory.stop(); screen.stop(); phoneSettings.stop()
            meetings.gate.lock()
            screen.gate.lock()
        }
    }

    /// A Today item opens the tab that holds its target. A session opens its detail.
    private func open(_ target: TodayTarget) {
        guard let next = AppTab.tab(for: target) else { return }
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
