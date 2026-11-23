import IronPetKit
import SwiftUI

/// The settings the Mac lets the phone change. Where data goes (voice server, Telegram, hooks) and the approval rules stay on the Mac.
struct PhoneSettingsView: View {
    let model: PhoneSettingsModel
    @Environment(VoiceModel.self) private var voice: VoiceModel?
    @AppStorage(ChatTextSize.storageKey) private var chatTextSize = ChatTextSize.default.rawValue

    var body: some View {
        Form {
            Group {
                Section("Chat") {
                    Picker("Chat text size", selection: $chatTextSize) {
                        ForEach(ChatTextSize.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .accessibilityIdentifier("chat-text-size")
                }
                if let message = model.errorMessage {
                    Label(message, systemImage: SharedSymbols.warning).foregroundStyle(.orange).accessibilityIdentifier("settings-error")
                }
                if let config = model.config {
                    Section("Reminders") {
                        Toggle("Pause reminders", isOn: binding(config.reminders.paused) { ["reminders": ["paused": $0]] })
                            .accessibilityIdentifier("reminders-paused")
                    }
                    Section("Tasks") {
                        Toggle("Remind me when a task is due", isOn: binding(config.tasks.dueReminders) { ["tasks": ["dueReminders": $0]] })
                        Toggle("Suggest tasks after meetings", isOn: binding(config.tasks.meetingSuggestions) { ["tasks": ["meetingSuggestions": $0]] })
                    }
                    if let voice { VoiceSettingsSection(voice: voice) }
                    Section("Ghost") {
                        Toggle("Welcome-back summary", isOn: binding(config.welcomeBack.enabled) { ["welcomeBack": ["enabled": $0]] })
                        Toggle("Read replies aloud", isOn: binding(config.speech.enabled) { ["speech": ["enabled": $0]] })
                    }
                    Section {
                        if config.meetings.enabled {
                            Button("Turn off meeting transcripts", role: .destructive) { Task { await model.patch(["meetings": ["enabled": false]]) } }
                                .accessibilityIdentifier("meetings-off")
                        } else {
                            LabeledContent("Meeting transcripts", value: "Off")
                        }
                        if config.screenCapture.enabled {
                            Button("Turn off screen capture", role: .destructive) { Task { await model.patch(["screenCapture": ["enabled": false]]) } }
                                .accessibilityIdentifier("screen-off")
                        } else {
                            LabeledContent("Screen capture", value: "Off")
                        }
                    } header: {
                        Text("Privacy")
                    } footer: {
                        Text("These can be turned off here and turned on only on the Mac.")
                    }
                }
                if !model.pets.isEmpty {
                    Section("Pet") {
                        ForEach(model.pets) { pet in
                            Button {
                                Task { await model.select(pet) }
                            } label: {
                                HStack {
                                    Text(pet.name).foregroundStyle(.primary)
                                    Spacer()
                                    if pet.selected { Image(systemName: SharedSymbols.allow).foregroundStyle(.tint) }
                                }
                            }
                            .accessibilityIdentifier("pet-\(pet.id)")
                        }
                    }
                }
                if let usage = model.usage {
                    Section("Usage, last \(usage.days) days") {
                        if usage.rows.isEmpty { Text("Nothing recorded").foregroundStyle(.secondary) }
                        ForEach(usage.rows) { row in
                            LabeledContent("\(row.feature) · \(row.model)", value: "\(row.requests) requests")
                        }
                        if usage.hasCost { LabeledContent("Cost today", value: usage.todayCost.formatted(.number.precision(.fractionLength(2)))) }
                    }
                }
        
            }.listRowBackground(SharedTheme.card)
        }
        .navigationTitle("Settings")
        .themedScreen()
        .refreshable { await model.refresh() }
        .task { model.start() }
    }

    private func binding(_ value: Bool, patch: @escaping (Bool) -> [String: Any]) -> Binding<Bool> {
        Binding(get: { value }, set: { next in Task { await model.patch(patch(next)) } })
    }
}
