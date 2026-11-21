import IronPetKit
import SwiftUI

@main
struct IronPetRemoteApp: App {
    @State private var model: AppModel

    init() {
        let store = KeychainCredentialStore()
        #if DEBUG
        // UI tests start from an unpaired app.
        if ProcessInfo.processInfo.arguments.contains("--reset-credentials") { store.delete() }
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
    @State private var tasks: TasksModel
    @State private var pet: PetModel
    @State private var chat: ChatModel
    @State private var today: TodayModel
    @State private var agents: AgentsModel
    @State private var alerts: AlertsModel
    @State private var automations: AutomationsModel
    @State private var meetings: MeetingsModel
    @State private var screen: ScreenModel
    @State private var phoneSettings: PhoneSettingsModel
    @State private var morePath: [MoreDestination] = []
    private let client: IronPetClient

    init(model: AppModel, device: PairedDevice) {
        self.model = model
        let client = IronPetClient(endpoint: device.endpoint, token: device.token)
        self.client = client
        // The Mac allows three sockets per device and five screens want events, so they share one.
        let events = SharedEventSource(EventConnection(client: client))
        let unauthorized: () -> Void = { [weak model] in model?.handleUnauthorized() }
        _tasks = State(initialValue: TasksModel(client: client, events: events, onUnauthorized: unauthorized))
        _pet = State(initialValue: PetModel(client: client, events: events, cache: AssetCache(directory: Self.assetsDirectory), onUnauthorized: unauthorized))
        _chat = State(initialValue: ChatModel(client: client, events: events, onUnauthorized: unauthorized))
        _today = State(initialValue: TodayModel(client: client, events: events, onUnauthorized: unauthorized))
        _agents = State(initialValue: AgentsModel(client: client, events: events, onUnauthorized: unauthorized))
        _alerts = State(initialValue: AlertsModel(client: client, events: events, onUnauthorized: unauthorized))
        _automations = State(initialValue: AutomationsModel(client: client, events: events, onUnauthorized: unauthorized))
        _meetings = State(initialValue: MeetingsModel(client: client, events: events, gate: TranscriptGate(authenticator: Self.authenticator), onUnauthorized: unauthorized))
        _screen = State(initialValue: ScreenModel(client: client, events: events, gate: TranscriptGate(authenticator: Self.authenticator, reason: "Show screen text"),
                                                  onUnauthorized: unauthorized))
        _phoneSettings = State(initialValue: PhoneSettingsModel(client: client, events: events, onUnauthorized: unauthorized))
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
                .tabItem { Label("Pet", systemImage: "pawprint.fill") }.tag(AppTab.pet)
            ChatView(model: chat, backgroundID: pet.backgroundID, backgroundImage: pet.backgroundImage)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.badge(chat.approvals.count + chat.forms.count).tag(AppTab.chat)
            TasksView(model: tasks)
                .tabItem { Label("Tasks", systemImage: "checklist") }.tag(AppTab.tasks)
            AgentsView(model: agents)
                .tabItem { Label("Agents", systemImage: "terminal") }.tag(AppTab.agents)
            MoreView(alerts: alerts, automations: automations, meetings: meetings, screen: screen, settings: phoneSettings, path: $morePath)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }.badge(alerts.alerts.count + automations.automations.filter(\.waitsForApproval).count)
                .tag(AppTab.more)
        }
        // The alert count and the waiting approvals are on their tabs before the user opens it.
        .task { alerts.start(); chat.start(); pet.start(); automations.start() }
        // The five minutes count from the app going to the background, whichever screen is open. Watching only inside the Meetings
        // screen would leave the text unlocked after the person left it and then left the app.
        .onChange(of: scenePhase) { _, phase in
            meetings.gate.scenePhaseChanged(phase)
            screen.gate.scenePhaseChanged(phase)
        }
        // A background changed on the Mac shows when the Chat tab opens.
        .onChange(of: tab) { _, next in if next == .chat { Task { await pet.reloadPet(applyMood: false) } } }
        // Leaving the tabs (unpair or a 401) must close the socket, which otherwise keeps reconnecting with the old token.
        .onDisappear { [tasks, pet, chat, today, agents, alerts, automations, meetings, screen, phoneSettings] in
            tasks.stop(); pet.stop(); chat.stop(); today.stop(); agents.stop(); alerts.stop(); automations.stop(); meetings.stop(); screen.stop(); phoneSettings.stop()
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
