import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import SwiftUI

/// What Settings → Memory shows and does: the learning settings and the data totals, with Export and Forget Everything. The pages
/// themselves are in the Memory section of the ironpet window (`MemorySection`). The rules live in `EntityMemoryStore`, behind
/// `MemoryAPI`; this only calls the API and keeps the page's state.
@MainActor
final class MemorySettingsModel: ObservableObject {
    /// Probes for installed agents. `AppDelegate` sets the Mac one.
    var spawner: ProcessSpawner = UnsupportedProcessSpawner()
    let api: MemoryAPI
    private weak var reflector: MemoryReflector?
    /// Why the last reflection pass failed, until one succeeds.
    @Published private(set) var lastError: String?
    @Published private(set) var entities: [MemoryEntity] = []
    /// How many valid claims each entity has, by id.
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var message: String?

    init(api: MemoryAPI, reflector: MemoryReflector? = nil) {
        self.api = api
        self.reflector = reflector
        reload()
    }

    func reload() {
        if let outcome = reflector?.lastOutcome, !outcome.skipped { lastError = outcome.error }
        entities = api.entities()
        counts = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, api.claims(of: $0.id).count) })
    }

    func forgetEverything() {
        reflector?.cancelAll()
        api.forgetEverything()
        reload()
    }

    /// Writes the Markdown copies of every page and opens the folder. A copy for reading; nothing reads it back.
    func exportAndOpen() {
        switch api.exportMarkdown() {
        case .success(let folder):
            message = nil
            NSWorkspace.shared.open(folder)
        case .failure(let failure):
            message = failure.message
        }
    }
}

/// Settings → Memory.
struct MemorySettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let memory = model.memory {
            MemorySettingsBody(memory: memory, onOpenSection: model.showMemorySection)
        } else {
            Form { Text("Memory is not available yet.").foregroundStyle(.secondary) }.formStyle(.grouped)
        }
    }
}

struct MemorySettingsBody: View {
    @ObservedObject var memory: MemorySettingsModel
    @ObservedObject private var store = SettingsAPI.live
    @State private var installedAgents: [ACPAgent] = []
    @State private var confirmForget = false
    /// Agents are not listed in previews, where no process may start.
    private let listsAgents: Bool
    /// Opens the Memory section of the ironpet window.
    private let onOpenSection: () -> Void

    init(memory: MemorySettingsModel, listsAgents: Bool = true, onOpenSection: @escaping () -> Void = {}) {
        self.memory = memory
        self.listsAgents = listsAgents
        self.onOpenSection = onOpenSection
    }

    private var config: Config.Memory { store.config.memory }
    private var petName: String { store.config.pet.name }

    var body: some View {
        Form {
                Section {
                    LabeledContent("Browse and search what \(petName) knows") {
                        Button(action: onOpenSection) { Label("Open Memory", systemImage: SharedSymbols.memory) }
                            .help("Open the Memory section of the ironpet window")
                    }
                }
                learningSection
                dataSection
            }
            .formStyle(.grouped)
        .task { if listsAgents { installedAgents = await ACPProbe.installed(spawner: memory.spawner) } }
        .onAppear { memory.reload() }
    }

    // MARK: Learning

    /// The installed agents, plus the saved one so the picker never shows a blank.
    private var agents: [ACPAgent] {
        var list = installedAgents
        if let id = config.reflectAgent, !list.contains(where: { $0.id == id }), let saved = AgentCatalog.agent(id: id) { list.append(saved) }
        return list
    }

    /// The models the agent reported in the chat, plus the saved id, so a model that is not listed still shows.
    private var modelChoices: [ChatModel] {
        var list = config.reflectAgent.map { ChatAPI.cachedModels(forAgent: $0).map { ChatModel(id: $0.id, name: $0.name) } } ?? []
        if let saved = config.reflectModel, !list.contains(where: { $0.id == saved }) { list.append(ChatModel(id: saved, name: saved)) }
        return list
    }

    private var learningSection: some View {
        Section {
            Toggle("Learn from chats", isOn: Binding(get: { config.reflect }, set: { on in store.update { $0.memory.reflect = on } }))
                .help("A chat goes to its own pet, a meeting summary to the summary harness and an automation's answer to the pet that ran it. It only answers: no tools, a scratch folder, every permission refused. Summaries and automation answers can only add notes about people. Notes with keys or passwords are never saved.")
            Picker("Harness", selection: Binding(get: { config.reflectAgent ?? "" }, set: setAgent)) {
                Text("Same as the chat (recommended)").tag("")
                ForEach(agents) { agent in Text(agent.name).tag(agent.id) }
            }
            .disabled(!config.reflect)
            if let agent = config.reflectAgent {
                Picker("Model", selection: Binding(get: { config.reflectModel ?? "" },
                                                   set: { id in store.update { $0.memory.reflectModel = id.isEmpty ? nil : id } })) {
                    Text(Config.Memory.cheapModels[agent].map { "Cheapest (\($0))" } ?? "Default").tag("")
                    ForEach(modelChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(!config.reflect)
            } else {
                LabeledContent("Model") { Text("Haiku for Claude Code, each harness's default for the others").foregroundStyle(.secondary) }
            }
            Stepper {
                Text("Learn every \(config.digestMinutes) min")
            } onIncrement: {
                let d = config.digestMinutes
                store.update { $0.memory.digestMinutes = min(Config.Memory.digestMinutesRange.upperBound, d < 60 ? d + 15 : d + 60) }
            } onDecrement: {
                let d = config.digestMinutes
                store.update { $0.memory.digestMinutes = max(Config.Memory.digestMinutesRange.lowerBound, d > 60 ? d - 60 : d - 15) }
            }
            .help("Once an hour, Ghost reads what is new in chats, meeting summaries and tasks, and merges any page that has grown too long.")
            .disabled(!config.reflect)
            Toggle("Learn from the screen", isOn: Binding(get: { config.learnFromScreen }, set: { on in store.update { $0.memory.learnFromScreen = on } }))
                .disabled(!config.reflect || (!store.config.screenCapture.enabled && !config.learnFromScreen))
                .help("Also reads the text of the screen captures that screen capture saves, with the same harness as the chats. Off by default.")
            if config.reflect, let error = memory.lastError {
                Label("The last pass failed: \(error)", systemImage: SharedSymbols.warning)
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        } header: {
            Text("Learning")
        } footer: {
Text("Once an hour, \(petName) sends what is new to the pet that already had it, which names the facts worth keeping. Each pass uses that pet's quota and shows as Memory in the Usage tab.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "" is Same as the chat. A model id from one agent means nothing to another, so a change clears it.
    private func setAgent(_ agent: String) {
        let picked = agent.isEmpty ? nil : agent
        store.update {
            if $0.memory.reflectAgent != picked { $0.memory.reflectModel = nil }
            $0.memory.reflectAgent = picked
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            HStack {
                let facts = memory.counts.values.reduce(0, +)
                Text("\(facts) fact\(facts == 1 ? "" : "s") on \(memory.entities.count) page\(memory.entities.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export Markdown", action: memory.exportAndOpen)
                Button("Forget Everything…", role: .destructive) { confirmForget = true }
                    .disabled(facts == 0)
                    .confirmationDialog("Forget everything \(petName) has learned?", isPresented: $confirmForget) {
                        Button("Forget Everything", role: .destructive, action: memory.forgetEverything)
                    } message: {
                        Text("Deletes every page, fact and its history, and the search index for them. This cannot be undone. Your chats and meetings stay.")
                    }
            }
            if let message = memory.message {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Stored on this Mac in ironpet.db. Export writes a Markdown copy of each page to ~/.ironpet/memory-export for reading; ironpet does not read it back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
