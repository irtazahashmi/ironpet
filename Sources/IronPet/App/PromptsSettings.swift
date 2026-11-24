import AppKit
import IronPetCore
import SwiftUI

/// What Settings → Prompts shows and does: each prompt ironpet sends on its own, with an editor, Reset to default and, when the
/// default changed under the user's edit, the lines that changed and a choice. The rules live in `PromptStore`; this calls
/// `PromptsAPI` only.
@MainActor
final class PromptsSettingsModel: ObservableObject {
    private let api: PromptsAPI
    @Published private(set) var prompts: [PromptsAPI.Prompt] = []
    @Published private(set) var selected: String?
    @Published var draft = ""
    @Published private(set) var message: String?

    init(api: PromptsAPI) {
        self.api = api
        reload()
    }

    var current: PromptsAPI.Prompt? { prompts.first { $0.id == selected } }
    var hasUnsavedEdit: Bool { draft != (current?.text ?? "") }

    func reload() {
        prompts = api.list()
        if current == nil {
            select(prompts.first?.id)
        } else if !hasUnsavedEdit, let current {
            draft = current.text
        }
    }

    func select(_ id: String?) {
        selected = id
        message = nil
        draft = current?.text ?? ""
    }

    func save() {
        guard let selected else { return }
        do {
            _ = try api.save(selected, text: draft)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    /// Restores the default. Also what "Use new default" does while an update waits.
    func reset() {
        guard let selected else { return }
        _ = try? api.reset(selected)
        message = nil
        reload()
        draft = current?.text ?? ""
    }

    func keepMine() {
        guard let selected else { return }
        _ = try? api.keepMine(selected)
        reload()
    }
}

/// Settings → Prompts.
struct PromptsSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let api = model.prompts {
            PromptsSettingsBody(api: api)
        } else {
            Form { Text("Prompts are not available yet.").foregroundStyle(.secondary) }.formStyle(.grouped)
        }
    }
}

struct PromptsSettingsBody: View {
    @StateObject private var state: PromptsSettingsModel

    init(api: PromptsAPI) {
        _state = StateObject(wrappedValue: PromptsSettingsModel(api: api))
    }

    var body: some View {
        Form {
            Section {
                Text("What Ghost tells the agent on its own. Changes apply to the next run. Words in braces, such as {name}, are filled in on each run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Prompt", selection: Binding(get: { state.selected ?? "" }, set: { state.select($0) })) {
                    ForEach(state.prompts, id: \.id) { Text($0.title).tag($0.id) }
                }
            }
            if let prompt = state.current {
                if let update = prompt.update { updateSection(update) }
                editorSection(prompt)
            }
        }
        .formStyle(.grouped)
        .onAppear { state.reload() }
    }

    private func editorSection(_ prompt: PromptsAPI.Prompt) -> some View {
        Section {
            TextEditor(text: $state.draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .accessibilityLabel("\(prompt.title) text")
            if !prompt.placeholders.isEmpty {
                Text("Placeholders: " + prompt.placeholders.map { "{\($0)}" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(stateText(prompt.state))
                    .font(.caption)
                    .foregroundStyle(prompt.state == .updated ? Color.orange : Color.secondary)
                Spacer(minLength: 12)
                Button("Reset to default") { state.reset() }
                    .disabled(prompt.state == .standard && !state.hasUnsavedEdit)
                Button("Save") { state.save() }
                    .disabled(!state.hasUnsavedEdit)
                    .keyboardShortcut(.defaultAction)
            }
            if let message = state.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text(prompt.title)
        }
    }

    private func updateSection(_ update: PromptsAPI.Update) -> some View {
        Section {
            Text("Ghost's default for this prompt changed in an update. Your text is kept until you choose.")
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(update.changes.enumerated()), id: \.offset) { _, change in
                    Text((change.removed ? "− " : "+ ") + change.line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(change.removed ? Color.red : Color.green)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Spacer(minLength: 12)
                Button("Keep mine") { state.keepMine() }
                Button("Use new default") { state.reset() }
            }
        } header: {
            Text("A newer default is available")
        }
    }

    private func stateText(_ state: PromptStore.State) -> String {
        switch state {
        case .standard: "Default"
        case .edited: "Edited"
        case .updated: "Edited. A newer default is available."
        }
    }
}
