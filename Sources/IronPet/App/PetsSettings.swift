import AppKit
import IronPetCore
import SwiftUI

/// Settings → General → Pets: every pet, with add, remove and a details view. A pet is an agent record, and the user only sees pets.
/// The first pet is the one the app always had, so it can be edited but not turned off or removed. Each change goes through
/// `AgentRecordsAPI`, and the supervisor starts, restarts or stops the pet's process. The first pet's name and image still live in
/// `config.json`, which `IronPetAPI` copies onto its record.
struct PetsSection: View {
    @ObservedObject var api: AgentRecordsAPI
    @ObservedObject var gallery: PetGalleryModel
    var buildPet: (String) -> Void
    @State private var opened: String?
    @State private var failure: String?
    @State private var pendingRemove: AgentRecord?

    var body: some View {
        Section {
            ForEach(api.list(), id: \.id) { pet in
                PetRow(api: api, pet: pet, open: { opened = pet.id }, askRemove: { pendingRemove = $0 }, failure: $failure)
            }
            HStack {
                Button("Add pet") { add() }
                    .accessibilityIdentifier("add-pet")
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }
        } header: {
            Text("Pets")
        } footer: {
            Text("Each pet that is on runs its own chat and shows on screen. Turning one off stops its chat and hides it; its chats and automations stay. The first pet always stays.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: Binding(get: { opened.map(PetID.init) }, set: { opened = $0?.id })) { item in
            PetDetails(api: api, gallery: gallery, petID: item.id, buildPet: buildPet) { opened = nil }
        }
        .alert("Remove \(pendingRemove?.name ?? "this pet")?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let pet = pendingRemove { run { try api.delete(pet.id) } }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("Its chats and automations stay on disk but are no longer listed.")
        }
    }

    private func add() {
        let harness = api.chatAgent?.agentCli ?? ChatAgentPreference.defaultID
        run {
            let number = api.list().count + 1
            _ = try api.create(CreateAgentRequest(name: "Pet \(number)", agentCli: harness))
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

private struct PetID: Identifiable { let id: String }

/// One line of the list: the pet's image, name and harness, the on switch and the remove button. Clicking the line opens the details.
private struct PetRow: View {
    @ObservedObject var api: AgentRecordsAPI
    let pet: AgentRecord
    let open: () -> Void
    let askRemove: (AgentRecord) -> Void
    @Binding var failure: String?
    @ObservedObject private var store = SettingsAPI.live

    private var isFirst: Bool { pet.id == AgentRegistry.chatAgentID }
    private var name: String { isFirst ? store.config.pet.name : pet.name }
    private var sprite: String? { isFirst ? store.config.pet.sprite : pet.pet }

    var body: some View {
        HStack {
            Button(action: open) {
                HStack(spacing: 10) {
                    PetThumb(sprite: sprite)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).fontWeight(.medium)
                        Text(AgentCatalog.agent(id: pet.agentCli)?.name ?? pet.agentCli).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pet-row-\(pet.id)")
            .accessibilityLabel("\(name), \(AgentCatalog.agent(id: pet.agentCli)?.name ?? pet.agentCli)")
            if !isFirst {
                Toggle("On", isOn: Binding(get: { pet.enabled }, set: { on in apply(UpdateAgentRequest(id: pet.id, enabled: on)) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(pet.enabled ? "Turn off: stops its chat and hides it" : "Turn on: starts its chat and shows it")
            }
            Button { askRemove(pet) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(!api.canRemove(pet.id))
                .help(api.canRemove(pet.id) ? "Remove \(name)" : "The first pet always stays")
                .accessibilityIdentifier("remove-pet-\(pet.id)")
                .accessibilityLabel("Remove \(name)")
        }
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

/// A still frame of a pet's sheet. The sheet is decoded off the main thread and only the one frame is kept.
private struct PetThumb: View {
    let sprite: String?
    @State private var frame: CGImage?

    var body: some View {
        Group {
            if let frame {
                Image(decorative: frame, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: 32, height: 35)
        .task(id: sprite ?? "") {
            let sprite = sprite
            frame = await Task.detached { Atlas.loadDefault(sprite: sprite)?.frame(.idle, 0) }.value
        }
    }
}

/// The sheet that opens from a pet's line: its image, name, harness, model and instructions. The harness and the image apply at
/// once. The name, model and instructions apply on Return, on Done, and when the sheet closes, so a restart of the pet's chat
/// happens once and not on every keystroke.
struct PetDetails: View {
    @ObservedObject var api: AgentRecordsAPI
    @ObservedObject var gallery: PetGalleryModel
    let petID: String
    var buildPet: (String) -> Void
    let close: () -> Void
    @ObservedObject private var store = SettingsAPI.live

    @State private var name = ""
    @State private var model = ""
    @State private var instructions = ""
    @State private var failure: String?
    @State private var loaded = false

    private var isFirst: Bool { petID == AgentRegistry.chatAgentID }
    private var pet: AgentRecord? { try? api.get(petID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PetGallery(gallery: gallery, petID: petID, records: api, buildPet: buildPet)
                    Form {
                        TextField("Name", text: $name).onSubmit(save)
                        Picker("Harness", selection: Binding(get: { pet?.agentCli ?? "" }, set: { apply(UpdateAgentRequest(id: petID, agentCli: $0)); model = pet?.model ?? "" })) {
                            ForEach(AgentCatalog.all) { Text($0.name).tag($0.id) }
                        }
                        TextField("Model", text: $model, prompt: Text("Empty for the harness's default")).onSubmit(save)
                    }
                    .formStyle(.columns)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instructions").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $instructions)
                            .font(.system(size: 12))
                            .frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                            .accessibilityLabel("Instructions")
                    }
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { save(); close() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pet-details-done")
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private func load() {
        guard !loaded, let pet else { return }
        loaded = true
        name = isFirst ? store.config.pet.name : pet.name
        model = pet.model ?? ""
        instructions = pet.instructions
    }

    private func save() {
        guard loaded else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failure = "A pet needs a name."
            return
        }
        if isFirst {
            if store.config.pet.name != trimmed { store.update { $0.pet.name = trimmed } }
            apply(UpdateAgentRequest(id: petID, model: model, instructions: instructions))
        } else {
            apply(UpdateAgentRequest(id: petID, name: trimmed, model: model, instructions: instructions))
        }
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
