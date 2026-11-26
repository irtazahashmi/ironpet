import IronPetKit
import SwiftUI

/// The conversation with the agent on this phone.
struct PhoneAgentView: View {
    let model: PhoneAgentModel
    @State private var draft = ""
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.waiting.isEmpty {
                Label("\(model.waiting.count) item\(model.waiting.count == 1 ? "" : "s") waiting for the Mac", systemImage: SharedSymbols.sentAt)
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                    .accessibilityIdentifier("phone-agent-waiting")
            }
            if model.messages.isEmpty {
                ContentUnavailableView(model.hasKey ? "Ask the agent on this phone" : "Add an API key",
                                       systemImage: SharedSymbols.chat,
                                       description: Text(model.hasKey ? "It adds inbox items, reads the calendar and answers without the Mac. Coding and the Mac's screen need the agent on the Mac."
                                                                     : "The agent on this phone calls Claude or OpenAI directly. Add a key in its settings."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { PhoneAgentRow(message: $0) }
                    }.padding(16)
                }.defaultScrollAnchor(.bottom)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("phone-agent-input")
                    .onSubmit(send)
                Button(action: model.isRunning ? model.cancelRun : send) {
                    Image(systemName: model.isRunning ? SharedSymbols.stop : SharedSymbols.send)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("phone-agent-send")
            }.padding(12)
        }
        .navigationTitle(PhoneAgentModel.agentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New conversation", systemImage: SharedSymbols.newChat) { model.newConversation() }
                    Button("Settings", systemImage: SharedSymbols.settings) { showsSettings = true }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("phone-agent-menu")
            }
        }
        .sheet(isPresented: $showsSettings) { NavigationStack { PhoneAgentSettingsView(model: model) } }
        .themedScreen()
        .task { model.start() }
    }

    private func send() {
        model.send(draft)
        draft = ""
    }
}

private struct PhoneAgentRow: View {
    let message: PhoneAgentModel.Message

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text).padding(10).background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12)).frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(message.text, systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary)
        case .error:
            Text(message.text).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Provider, model and API key. The key goes to the Keychain and is never shown again.
struct PhoneAgentSettingsView: View {
    let model: PhoneAgentModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AgentProvider = .anthropic
    @State private var modelName = ""
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $provider) { ForEach(AgentProvider.allCases) { Text($0.label).tag($0) } }.accessibilityIdentifier("phone-agent-provider")
                TextField("Model", text: $modelName, prompt: Text(provider.defaultModel)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("phone-agent-model")
            }
            Section {
                SecureField(model.hasKey && provider == model.config.provider ? "Saved in the Keychain" : "API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.password).accessibilityIdentifier("phone-agent-key")
                if model.hasKey, provider == model.config.provider {
                    Button("Remove key", role: .destructive) { model.removeKey() }
                }
            } header: { Text("API key") } footer: { Text("The key stays in this phone's Keychain. It is sent only to \(provider.label).") }
            Section("Mac") { Text(registrationText).foregroundStyle(.secondary).accessibilityIdentifier("phone-agent-registration") }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Phone agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).accessibilityIdentifier("phone-agent-save") }
        }
        .onAppear { provider = model.config.provider; modelName = model.config.model }
    }

    private var registrationText: String {
        switch model.registration {
        case .notConfigured: return "Add a key to register this agent with your Mac."
        case .pending(let reason): return reason
        case .registered(let record): return "Registered with your Mac as \(record.displayName)."
        }
    }

    private func save() {
        Task {
            do {
                try await model.save(provider: provider, model: modelName, key: key)
                key = ""
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
