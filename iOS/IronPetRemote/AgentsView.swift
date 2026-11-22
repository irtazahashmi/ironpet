import IronPetKit
import SwiftUI

struct AgentsView: View {
    let model: AgentsModel
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    if let message = model.errorMessage {
                        Label(message, systemImage: SharedSymbols.warning).foregroundStyle(.orange).accessibilityIdentifier("agents-error")
                    }
                    section("Needs you", id: "needs-input", model.needsInput)
                    section("Running", id: "running", model.running)
                    section("Finished", id: "finished", model.finished)
                    if model.loaded, model.agents.isEmpty {
                        ContentUnavailableView("No agents", systemImage: SharedSymbols.agents, description: Text("Coding agents that Ghost watches on the Mac show up here."))
                    }
            
                }.listRowBackground(SharedTheme.card)
            }
            .navigationTitle("Agents")
            .themedScreen()
            .refreshable { await model.refresh() }
            .navigationDestination(for: String.self) { id in AgentDetailView(model: model, id: id) }
            .onChange(of: model.pendingDetail) { _, id in
                if let id { path = [id]; model.pendingDetail = nil }
            }
        }
        .task {
            model.start()
            if let id = model.pendingDetail { path = [id]; model.pendingDetail = nil }
        }
    }

    @ViewBuilder private func section(_ title: String, id: String, _ items: [RemoteAgent]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { agent in
                    NavigationLink(value: agent.id) { AgentRow(agent: agent) }.accessibilityIdentifier("agent-\(agent.id)")
                }
            } header: {
                Text(title).textCase(nil).font(.headline).foregroundStyle(.primary).accessibilityIdentifier("agents-section-\(id)")
            }
        }
    }
}

struct AgentRow: View {
    let agent: RemoteAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(agent.workspace).font(.headline)
                Spacer()
                Text(agent.statusLabel).font(.caption).foregroundStyle(color)
            }
            Text(agent.sourceName).font(.caption).foregroundStyle(.secondary)
            if let line = agent.status == .needsInput ? (agent.detail ?? agent.prompt) : (agent.summary ?? agent.prompt) {
                Text(line).font(.subheadline).lineLimit(2)
            }
        }
    }

    private var color: Color {
        switch agent.status {
        case .needsInput: return .orange
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}

struct AgentDetailView: View {
    let model: AgentsModel
    let id: String
    @State private var agent: RemoteAgent?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Group {
                if let agent {
                    Section {
                        LabeledContent("Agent", value: agent.sourceName)
                        LabeledContent("Status", value: agent.statusLabel)
                        LabeledContent("Updated", value: agent.updated.formatted(date: .omitted, time: .shortened))
                    }
                    if let prompt = agent.prompt { Section("Prompt") { Text(prompt) } }
                    if let detail = agent.detail { Section("Waiting for") { Text(detail) } }
                    if let summary = agent.summary { Section("Summary") { Text(summary) } }
                    if !agent.editedFiles.isEmpty {
                        Section("Edited files") { ForEach(agent.editedFiles, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent) } }
                    }
                    if let reply = agent.lastResponse { Section("Last reply") { Text(reply).font(.callout) } }
                    Section {
                        if agent.canAcknowledge {
                            Button("Mark as seen") { Task { await model.acknowledge(agent); dismiss() } }.accessibilityIdentifier("acknowledge-button")
                        }
                        Button("Ask Ghost about this") { Task { await model.ask(agent) } }.accessibilityIdentifier("ask-agent-button")
                    } footer: {
                        if let notice = model.notice { Text(notice).accessibilityIdentifier("agent-notice") }
                    }
                } else {
                    ProgressView()
                }
        
            }.listRowBackground(SharedTheme.card)
        }
        .navigationTitle(agent?.workspace ?? "Agent")
        .themedScreen()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.notice = nil
            agent = await model.detail(id)
        }
    }
}
