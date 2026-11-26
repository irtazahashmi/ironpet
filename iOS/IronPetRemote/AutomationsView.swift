import IronPetKit
import SwiftUI

/// The text shown while the Mac waits for the user. The phone has no button for it.
let waitingForApproveText = "Waiting for Approve on the Mac"

struct AutomationsView: View {
    let model: AutomationsModel
    @State private var asking = false
    @State private var request = ""
    @State private var creating = false
    @State private var deleting: RemoteAutomation?

    var body: some View {
        List {
            Group {
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle").accessibilityIdentifier("automations-notice")
                }
                ForEach(model.automations) { automation in
                    NavigationLink {
                        AutomationDetailView(model: model, id: automation.id)
                    } label: {
                        AutomationRow(automation: automation)
                    }
                    .accessibilityIdentifier("automation-\(automation.id)")
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = automation }
                    }
                }
                if model.loaded, model.automations.isEmpty {
                    ContentUnavailableView("No automations", systemImage: SharedSymbols.automations,
                                           description: Text("Reminders and watchers you make show up here."))
                }
        
            }.listRowBackground(SharedTheme.card)
        }
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .fullPageLoadError(model)
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New automation…") { asking = true }.accessibilityIdentifier("new-automation-request")
                    Button("From JSON…") { creating = true }.accessibilityIdentifier("new-automation-json")
                } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("new-automation-menu")
            }
        }
        .sheet(isPresented: $asking) {
            NavigationStack {
                Form {
                    Group {
                        Section {
                            TextField("What should it do, and when?", text: $request, axis: .vertical).lineLimit(3...8)
                                .accessibilityIdentifier("automation-request-field")
                        } footer: {
                            Text("Ghost builds it in the chat on your Mac. Anything that runs a command waits for Approve there.")
                        }
                
                    }.listRowBackground(SharedTheme.card)
                }
                .navigationTitle("New automation")
                .themedScreen()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { asking = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            let text = request
                            Task { if await model.request(text) { request = ""; asking = false } }
                        }
                        .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("automation-request-send")
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            AutomationEditor(title: "New automation", initial: Self.template, save: { await model.create(definition: $0) })
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this automation")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleting { Task { await model.delete(target) } }
                deleting = nil
            }
        }
        .task { model.start() }
    }

    static let template = """
    {
      "name": "Stand up",
      "trigger": { "type": "daily", "times": ["10:00"], "weekdays": ["mon", "tue", "wed", "thu", "fri"] },
      "action": { "type": "bubble", "title": "Stand up", "body": "Time to stretch." }
    }
    """
}

struct AutomationRow: View {
    let automation: RemoteAutomation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(automation.name).font(.headline)
                if !automation.enabled { Text("Paused").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("paused-\(automation.id)") }
            }
            Text(automation.trigger).font(.subheadline).foregroundStyle(.secondary)
            if automation.waitsForApproval {
                Label(waitingForApproveText, systemImage: SharedSymbols.approval)
                    .font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("approval-\(automation.id)")
            } else if let last = automation.lastRun {
                Text("Last run: \(last.outcome)").font(.footnote).foregroundStyle(last.outcome == "failed" ? .red : .secondary)
            }
        }
    }
}

struct AutomationDetailView: View {
    let model: AutomationsModel
    let id: String
    @State private var automation: RemoteAutomation?
    @State private var history: [RemoteAutomationRun] = []
    @State private var log: [RemoteAutomationLogEntry] = []
    @State private var editing = false

    var body: some View {
        List {
            Group {
                if let automation {
                    Section {
                        LabeledContent("Runs", value: automation.trigger)
                        if let next = automation.nextRun, automation.enabled { LabeledContent("Next", value: next.formatted(date: .abbreviated, time: .shortened)) }
                        LabeledContent("Made by", value: automation.createdBy)
                        if let stream = automation.stream { LabeledContent("Stream", value: stream) }
                        if let ref = automation.ref { RecordIDLine(ref: ref) }
                    }
                    if automation.waitsForApproval {
                        Section {
                            Label(waitingForApproveText, systemImage: SharedSymbols.approval).foregroundStyle(.orange)
                                .accessibilityIdentifier("detail-approval")
                            if let detail = automation.approvalDetail { Text(detail).font(.footnote.monospaced()).textSelection(.enabled) }
                        } footer: {
                            Text("Approve and Reject are only on the Mac.")
                        }
                    } else {
                        Section {
                            Button("Run now") { Task { await model.runNow(automation); await load() } }.accessibilityIdentifier("run-now")
                        }
                    }
                    Section {
                        Button(automation.enabled ? "Pause" : "Resume") {
                            Task { await model.setPaused(automation, automation.enabled); await load() }
                        }.accessibilityIdentifier("pause-resume")
                        Button("Edit…") { editing = true }.accessibilityIdentifier("edit-automation")
                    }
                    Section("History") {
                        if history.isEmpty { Text("No runs yet").foregroundStyle(.secondary) }
                        ForEach(Array(history.enumerated()), id: \.offset) { _, run in
                            VStack(alignment: .leading) {
                                Text("\(run.date.formatted(date: .abbreviated, time: .shortened)) · \(run.outcome)").font(.footnote)
                                if !run.output.isEmpty { Text(run.output).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            }
                        }
                    }
                    Section("Log") {
                        if log.isEmpty { Text("Nothing logged").foregroundStyle(.secondary) }
                        ForEach(log) { entry in
                            VStack(alignment: .leading) {
                                Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.outcome)").font(.footnote)
                                Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
        
            }.listRowBackground(SharedTheme.card)
        }
        .navigationTitle(automation?.name ?? "Automation")
        .themedScreen()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            if let automation {
                AutomationEditor(title: "Edit \(automation.name)", initial: automation.definition ?? "{}", save: { text in
                    let saved = await model.update(automation, changes: text)
                    if saved { await load() }
                    return saved
                })
            }
        }
        .task { await load() }
        .onChange(of: model.automations) { _, _ in Task { await load() } }
    }

    private func load() async {
        automation = await model.detail(id)
        history = await model.history(id)
        log = await model.log(id)
    }
}

/// A JSON editor for creating or changing an automation. The Mac validates it and says what is wrong.
struct AutomationEditor: View {
    let title: String
    @State var text: String
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    init(title: String, initial: String, save: @escaping (String) async -> Bool) {
        self.title = title
        _text = State(initialValue: initial)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextEditor(text: $text)
                            .font(.footnote.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(minHeight: 260)
                            .accessibilityIdentifier("automation-json")
                    } footer: {
                        Text("A change to what it runs makes it wait for Approve on the Mac again.")
                    }
            
                }.listRowBackground(SharedTheme.card)
            }
            .navigationTitle(title)
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            if await save(text) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("automation-json-save")
                }
            }
        }
    }
}
