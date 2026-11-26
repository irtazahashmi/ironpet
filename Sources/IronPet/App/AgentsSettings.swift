import IronPetCore
import SwiftUI

/// Settings → Agents: create, edit, disable and delete agents. Agent 1 is the pet the app always had, so it can be edited but not
/// disabled or deleted. Each change goes through `AgentRecordsAPI`, and the supervisor starts, restarts or stops the agent's process.
struct AgentsSettings: View {
    @ObservedObject var api: AgentRecordsAPI
    @State private var expanded: String?
    @State private var failure: String?
    @State private var pendingDelete: AgentRecord?

    var body: some View {
        Form {
            Section {
                ForEach(api.list(), id: \.id) { agent in
                    AgentRow(api: api, agent: agent, isExpanded: expanded == agent.id, failure: $failure, askDelete: { pendingDelete = $0 }) {
                        expanded = expanded == agent.id ? nil : agent.id
                    }
                }
                HStack {
                    Button("Add agent") { add() }
                        .accessibilityIdentifier("add-agent")
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }
            } footer: {
                Text("Each enabled agent runs its own agent process and shows its own pet. Disabling an agent stops its process and hides its pet; its chats and automations stay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Delete \(pendingDelete?.name ?? "agent")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let agent = pendingDelete { run { try api.delete(agent.id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its chats and automations stay on disk but are no longer listed.")
        }
    }

    private func add() {
        let cli = api.chatAgent?.agentCli ?? ChatAgentPreference.defaultID
        run {
            let number = api.list().count + 1
            let created = try api.create(CreateAgentRequest(name: "Agent \(number)", agentCli: cli))
            expanded = created.id
        }
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
            failure = nil
        } catch {
            failure = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}

private struct AgentRow: View {
    @ObservedObject var api: AgentRecordsAPI
    let agent: AgentRecord
    let isExpanded: Bool
    @Binding var failure: String?
    let askDelete: (AgentRecord) -> Void
    let toggle: () -> Void

    @State private var name = ""
    @State private var model = ""
    @State private var pet = ""
    @State private var instructions = ""

    private var isFirst: Bool { agent.id == AgentRegistry.chatAgentID }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: toggle) {
                    HStack {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 10)
                        Text(agent.name).fontWeight(.medium)
                        Text(AgentCatalog.agent(id: agent.agentCli)?.name ?? agent.agentCli).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if !isFirst {
                    Toggle("Enabled", isOn: Binding(get: { agent.enabled }, set: { on in apply(UpdateAgentRequest(id: agent.id, enabled: on)) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(agent.enabled ? "Disable: stops its process and hides its pet" : "Enable: starts its process and shows its pet")
                }
            }
            if isExpanded {
                TextField("Name", text: $name).onSubmit { save() }
                    .disabled(isFirst)
                    .help(isFirst ? "Agent 1 is named in General" : "")
                Picker("Agent CLI", selection: Binding(get: { agent.agentCli }, set: { apply(UpdateAgentRequest(id: agent.id, agentCli: $0)) })) {
                    ForEach(AgentCatalog.all) { Text($0.name).tag($0.id) }
                }
                TextField("Model (empty for the CLI's default)", text: $model).onSubmit { save() }
                TextField("Pet sprite sheet path (empty for the default pet)", text: $pet).onSubmit { save() }
                    .disabled(isFirst)
                    .help(isFirst ? "Agent 1's pet is chosen in General" : "")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Instructions").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $instructions)
                        .font(.system(size: 12))
                        .frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                }
                HStack {
                    Button("Save") { save() }
                    if !isFirst { Button("Delete", role: .destructive) { askDelete(agent) } }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: agent) { _, _ in if !isExpanded { load() } }
        .onChange(of: isExpanded) { _, open in if open { load() } }
    }

    private func load() {
        name = agent.name
        model = agent.model ?? ""
        pet = agent.pet ?? ""
        instructions = agent.instructions
    }

    private func save() {
        apply(UpdateAgentRequest(id: agent.id, name: isFirst ? nil : name, pet: isFirst ? nil : pet, model: model, instructions: instructions))
    }

    private func apply(_ request: UpdateAgentRequest) {
        do {
            try api.update(request)
            failure = nil
        } catch {
            failure = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}
