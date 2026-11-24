import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import SwiftUI

/// What Settings → Memory shows and does: the pages and their claims, the recent changes with Undo, and search. The rules (writing,
/// undo, pinning) live in `EntityMemoryStore`, behind `MemoryAPI`; this only calls the API and keeps the page's state.
@MainActor
final class MemorySettingsModel: ObservableObject {
    /// Probes for installed agents. `AppDelegate` sets the Mac one.
    var spawner: ProcessSpawner = UnsupportedProcessSpawner()
    let api: MemoryAPI
    private weak var reflector: MemoryReflector?
    @Published private(set) var changes: [MemoryChange] = []
    /// Why the last reflection pass failed, until one succeeds.
    @Published private(set) var lastError: String?
    @Published private(set) var entities: [MemoryEntity] = []
    /// How many valid claims each entity has, by id.
    @Published private(set) var counts: [String: Int] = [:]
    /// The page open in the list, by entity id.
    @Published private(set) var selected: String?
    @Published private(set) var claims: [MemoryClaim] = []
    /// The claims the page used to hold, newest first.
    @Published private(set) var history: [MemoryClaim] = []
    @Published private(set) var message: String?
    /// Why the last Undo did nothing.
    @Published private(set) var undoMessage: String?

    init(api: MemoryAPI, reflector: MemoryReflector? = nil) {
        self.api = api
        self.reflector = reflector
        reload()
    }

    /// The page's name, for a change or a row.
    func name(of entity: String) -> String {
        entities.first { $0.id == entity }?.name ?? entity
    }

    func reload() {
        if let outcome = reflector?.lastOutcome, !outcome.skipped { lastError = outcome.error }
        changes = api.recentChanges(limit: 20)
        entities = api.entities()
        counts = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, api.claims(of: $0.id).count) })
        if selected == nil || !entities.contains(where: { $0.id == selected }) {
            selected = entities.first(where: { (counts[$0.id] ?? 0) > 0 })?.id ?? entities.first?.id
        }
        refreshPage()
    }

    func select(_ entity: String?) {
        selected = entity
        message = nil
        refreshPage()
    }

    private func refreshPage() {
        guard let selected else { claims = []; history = []; return }
        claims = api.claims(of: selected)
        history = api.history(of: selected)
    }

    func pin(_ claim: MemoryClaim) {
        _ = api.setPinned(claim.id, !claim.pinned)
        reload()
    }

    func undo(_ change: MemoryChange) {
        if case .failure(let failure) = api.undo(change) { undoMessage = failure.message } else { undoMessage = nil }
        reload()
    }

    func search(_ query: String) -> [MemoryIndex.Hit] {
        api.search(query, limit: 20)
    }

    func forgetEverything() {
        reflector?.cancelAll()
        api.forgetEverything()
        selected = nil
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
            MemorySettingsBody(memory: memory)
        } else {
            Form { Text("Memory is not available yet.").foregroundStyle(.secondary) }.formStyle(.grouped)
        }
    }
}

struct MemorySettingsBody: View {
    @ObservedObject var memory: MemorySettingsModel
    @ObservedObject private var store = SettingsAPI.live
    @State private var installedAgents: [ACPAgent] = []
    @State private var query = ""
    @State private var hits: [MemoryIndex.Hit] = []
    @State private var confirmForget = false
    /// Agents are not listed in previews, where no process may start.
    private let listsAgents: Bool

    init(memory: MemorySettingsModel, listsAgents: Bool = true) {
        self.memory = memory
        self.listsAgents = listsAgents
    }

    private var config: Config.Memory { store.config.memory }
    private var petName: String { store.config.pet.name }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                learningSection
                recentSection(scroll)
                pagesSection.id("pages")
                searchSection
                dataSection
            }
            .formStyle(.grouped)
        }
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
                .help("A chat goes to its own agent, a meeting summary to the summary agent and an automation's answer to the agent that ran it. The agent only answers: no tools, a scratch folder, every permission refused. Summaries and automation answers can only add notes about people. Notes with keys or passwords are never saved.")
            Picker("Agent", selection: Binding(get: { config.reflectAgent ?? "" }, set: setAgent)) {
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
                LabeledContent("Model") { Text("Haiku for Claude Code, each agent's default for the others").foregroundStyle(.secondary) }
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
                .help("Also reads the text of the screen captures that screen capture saves, with the same agent as the chats. Off by default.")
            if config.reflect, let error = memory.lastError {
                Label("The last pass failed: \(error)", systemImage: SharedSymbols.warning)
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        } header: {
            Text("Learning")
        } footer: {
Text("Once an hour, \(petName) sends what is new to the agent that already had it, which names the facts worth keeping. Each pass uses that agent's quota and shows as Memory in the Usage tab.")
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

    // MARK: Recently learned

    private func recentSection(_ scroll: ScrollViewProxy) -> some View {
        Section {
            if let message = memory.undoMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if memory.changes.isEmpty {
                Text("Nothing learned yet. Notes show up here as \(petName) saves them, with Undo.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(memory.changes) { change in
                ChangeRow(change: change, page: memory.name(of: change.file), undo: { memory.undo(change) }, edit: {
                    memory.select(change.file)
                    withAnimation { scroll.scrollTo("pages", anchor: .top) }
                })
            }
        } header: {
            Text("Recently learned")
        }
    }

    // MARK: Pages

    private var pagesSection: some View {
        Section {
            if memory.entities.isEmpty {
                Text("No pages yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Page", selection: Binding(get: { memory.selected ?? "" }, set: { memory.select($0.isEmpty ? nil : $0) })) {
                    ForEach(memory.entities) { entity in
                        let count = memory.counts[entity.id] ?? 0
                        Text(entity.isStub ? "\(entity.name) (stub)" : "\(entity.name) (\(count) fact\(count == 1 ? "" : "s"))").tag(entity.id)
                    }
                }
                if memory.claims.isEmpty {
                    Text("Nothing on this page yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(memory.claims) { claim in
                    ClaimRow(claim: claim, pin: { memory.pin(claim) })
                }
                if !memory.history.isEmpty {
                    DisclosureGroup("Earlier (\(memory.history.count))") {
                        ForEach(memory.history) { claim in
                            Text(claim.text).strikethrough().foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }
            }
        } header: {
            Text("Pages")
        } footer: {
            Text("Each page holds what \(petName) knows about one person, project or the user. A fact that changed is replaced and kept under Earlier. Pinned facts are never replaced: a newer fact is added beside them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Search

    private var searchSection: some View {
        Section {
            TextField("Search", text: $query, prompt: Text("Search chats, meetings and notes"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            if !query.trimmingCharacters(in: .whitespaces).isEmpty, hits.isEmpty {
                Text("Nothing found.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 2) {
                    Label(hit.title, systemImage: Self.symbol(hit.kind))
                        .font(.callout)
                    Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(hit.at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Search")
        } footer: {
            Text("The same search \(petName) uses with memory_search, without the screen captures.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            hits = query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : memory.search(query)
        }
    }

    static func symbol(_ kind: MemoryIndex.Kind) -> String {
        switch kind {
        case .chat: return SharedSymbols.chat
        case .meeting: return "person.2.wave.2"
        case .note: return "note.text"
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
                    .disabled(memory.entities.count <= 1 && memory.changes.isEmpty)
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

/// One change in Recently learned: what changed, on which page, from where, and Undo.
private struct ChangeRow: View {
    let change: MemoryChange
    let page: String
    let undo: () -> Void
    let edit: () -> Void

    private var text: String { MemoryNote.parse(change.note)?.text ?? change.note }

    private var symbol: String {
        switch change.action {
        case .added: return "plus.circle"
        case .forgot: return "minus.circle"
        case .replaced: return "arrow.triangle.2.circlepath"
        case .tidied: return "wand.and.stars"
        case .edited: return "pencil"
        }
    }

    private var verb: String {
        switch change.action {
        case .added: return "Learned"
        case .forgot: return "Forgot"
        case .replaced: return "Updated"
        case .tidied: return "Tidied"
        case .edited: return "Edited"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).strikethrough(change.undone).lineLimit(3)
                Text("\(verb) · \(change.section.map { $0 == page ? page : "\(page) · \($0)" } ?? page) · \(Self.origin(change.source)) · "
                     + change.at.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show", action: edit).controlSize(.small)
            Button(change.undone ? "Undone" : "Undo", action: undo).controlSize(.small).disabled(change.undone || change.claim == nil)
        }
        .accessibilityElement(children: .contain)
    }

    static func origin(_ source: String) -> String {
        if source.hasPrefix("chat:") { return "from a chat" }
        if source.hasPrefix(MemoryMCP.jobCaller) { return "from a background job" }
        if source.hasPrefix("meeting:") { return "from meeting \(source.dropFirst("meeting:".count))" }
        if source.hasPrefix("automation:") { return "from automation \(source.dropFirst("automation:".count))" }
        switch source {
        case MemoryNote.userSource: return "by you"
        default: return "by an agent"
        }
    }
}

/// One claim on a page: its text, the day and the source, and a pin.
private struct ClaimRow: View {
    let claim: MemoryClaim
    let pin: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(claim.text).lineLimit(3)
                Text([claim.date, claim.sources.last.map { ChangeRow.origin($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: pin) {
                Image(systemName: claim.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(claim.pinned ? "Unpin this fact" : "Pin this fact so a newer one is added beside it instead of replacing it")
            .accessibilityLabel(claim.pinned ? "Unpin" : "Pin")
        }
        .accessibilityElement(children: .contain)
    }
}
