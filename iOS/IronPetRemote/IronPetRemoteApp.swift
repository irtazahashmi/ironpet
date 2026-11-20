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

    var body: some Scene {
        WindowGroup { RootView(model: model) }
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
    @State private var tasks: TasksModel
    @State private var pet: PetModel
    @State private var today: TodayModel
    @State private var agents: AgentsModel
    @State private var alerts: AlertsModel
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
        _today = State(initialValue: TodayModel(client: client, events: events, onUnauthorized: unauthorized))
        _agents = State(initialValue: AgentsModel(client: client, events: events, onUnauthorized: unauthorized))
        _alerts = State(initialValue: AlertsModel(client: client, events: events, onUnauthorized: unauthorized))
    }

    /// `Application Support/assets`, where files live under their hash.
    static var assetsDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("assets", isDirectory: true)
    }

    var body: some View {
        TabView(selection: $tab) {
            PetView(model: pet, today: today, open: open)
                .tabItem { Label("Pet", systemImage: "pawprint.fill") }.tag(AppTab.pet)
            TasksView(model: tasks)
                .tabItem { Label("Tasks", systemImage: "checklist") }.tag(AppTab.tasks)
            AgentsView(model: agents)
                .tabItem { Label("Agents", systemImage: "terminal") }.tag(AppTab.agents)
            AlertsView(model: alerts)
                .tabItem { Label("Alerts", systemImage: "bell") }.badge(alerts.alerts.count).tag(AppTab.alerts)
            SettingsView(app: model, client: client)
                .tabItem { Label("Device", systemImage: "iphone") }.tag(AppTab.device)
        }
        // The alert count is on the tab before the user opens it.
        .task { alerts.start() }
        // Leaving the tabs (unpair or a 401) must close the socket, which otherwise keeps reconnecting with the old token.
        .onDisappear { [tasks, pet, today, agents, alerts] in tasks.stop(); pet.stop(); today.stop(); agents.stop(); alerts.stop() }
    }

    /// A Today item opens the tab that holds its target. A session opens its detail.
    private func open(_ target: TodayTarget) {
        guard let next = AppTab.tab(for: target) else { return }
        if target.type == .session { agents.pendingDetail = target.id }
        tab = next
    }
}
