import IronPetKit
import PhotosUI
import SwiftUI
import UIKit

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
                if let config = model.config { BackgroundSection(model: model, current: config.chat.background) }
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

/// The chat background, as the Mac's Settings offers it: Default, the built-ins and a custom image. A choice is sent to the Mac, which
/// tells every phone and itself. A photo from the library is uploaded to the Mac and becomes the custom image for all of them.
private struct BackgroundSection: View {
    let model: PhoneSettingsModel
    let current: String
    @Environment(\.macBackground) private var background
    @State private var photo: PhotosPickerItem?

    var body: some View {
        Section {
            // A wrapping grid, so every option shows without scrolling sideways, as the Mac's picker wraps.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                choice(ChatBackgrounds.defaultID, "Default")
                ForEach(ChatBackgrounds.builtIns) { choice($0.id, $0.name) }
                if current == ChatBackgrounds.customID { choice(ChatBackgrounds.customID, "Custom image") }
            }
            .padding(.vertical, 4)
            photoPicker
        } header: {
            Text("Chat background")
        } footer: {
            Text("The same background shows on the Mac and on this phone. A photo is sent to the Mac.")
        }
    }

    @ViewBuilder private var photoPicker: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--stub-photo") {
            // A simulator has no photos to pick, so UI tests send a generated one through the same upload.
            Button { Task { await model.uploadBackground(Self.samplePhoto) } } label: { Label("Choose a photo", systemImage: "photo") }
                .accessibilityIdentifier("background-photo")
        } else { realPicker }
        #else
        realPicker
        #endif
    }

    private var realPicker: some View {
        PhotosPicker(selection: $photo, matching: .images) { Label("Choose a photo", systemImage: "photo") }
            .accessibilityIdentifier("background-photo")
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task { if let data = try? await item.loadTransferable(type: Data.self) { await model.uploadBackground(data) } }
            }
    }

    private func choice(_ id: String, _ title: String) -> some View {
        let selected = current == id
        return Button { Task { await model.patch(["chat": ["background": id]]) } } label: {
            VStack(spacing: 4) {
                ChatBackgroundPicture(id: id, customImage: background.image.map(Image.init(uiImage:)), fallback: SharedTheme.window, scale: 0.45)
                    .frame(width: 76, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
                Text(title).font(.caption).lineLimit(1).foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) background")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("background-\(id)")
    }

    #if DEBUG
    private static var samplePhoto: Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        return renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
    }
    #endif
}
