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
    @State private var tasks: TasksModel

    init(model: AppModel, device: PairedDevice) {
        self.model = model
        let client = IronPetClient(endpoint: device.endpoint, token: device.token)
        _tasks = State(initialValue: TasksModel(client: client, onUnauthorized: { [weak model] in model?.handleUnauthorized() }))
    }

    var body: some View {
        TabView {
            TasksView(model: tasks)
                .tabItem { Label("Tasks", systemImage: "checklist") }
            SettingsView(app: model, client: tasks.client)
                .tabItem { Label("Device", systemImage: "iphone") }
        }
        // Leaving the tabs (unpair or a 401) must close the socket, which otherwise keeps reconnecting with the old token.
        .onDisappear { tasks.stop() }
    }
}
