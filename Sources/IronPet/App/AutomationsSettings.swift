import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import SwiftUI

/// The Automations tab: every reminder and watcher with a switch, when it runs next, and how its last run went.
struct AutomationsSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var config = SettingsAPI.live
    /// The automation to show in full when the tab appears. The preview renderer uses it.
    var open: String?

    var body: some View {
        if let service = model.automations {
            AutomationList(api: service, config: config, showLogs: model.showLogs, createWithAgent: model.createWithAgent, open: open)
        } else {
            ListScreen(title: IronPetSection.automations.title) {
                Text("Automations are not ready yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The Automations screen once the service is ready. Internal so the tests and the preview renderer can build it.
struct AutomationList: View {
    @ObservedObject var api: AutomationsAPI
    @ObservedObject var config: SettingsAPI
    let showLogs: (String?) -> Void
    let createWithAgent: (String) -> Void
    @State private var asking = false
    @State private var editing: Automation?
    @State private var reviewing: Automation?
    @State private var tick = 0
    @State private var search = ""
    @State private var nav: ListNavigation<String>

    init(api: AutomationsAPI, config: SettingsAPI, showLogs: @escaping (String?) -> Void, createWithAgent: @escaping (String) -> Void, open: String? = nil) {
        self.api = api
        self.config = config
        self.showLogs = showLogs
        self.createWithAgent = createWithAgent
        _nav = State(initialValue: ListNavigation(opened: open))
    }

    var body: some View {
        ListScreen(title: IronPetSection.automations.title, search: $search, detailOpen: nav.opened != nil) {
            if let id = nav.opened {
                detail(id)
            } else {
                form.listColumn()
            }
        }
        .sheet(isPresented: $asking) { NewAutomationSheet { text in asking = false; if let text { createWithAgent(text) } } }
        .sheet(item: $reviewing) { automation in ReviewSheet(api: api, opened: automation) { reviewing = nil } }
        .sheet(item: $editing) { automation in EditSheet(api: api, automation: automation) { editing = nil } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
    }

    /// The automations whose name or schedule line contains the search text.
    private var shown: [Automation] {
        ListSearch.filter(api.automations, query: search, title: \.name, description: { subtitle($0) })
    }

    @ViewBuilder private func detail(_ id: String) -> some View {
        let _ = tick
        if let a = api.automations.first(where: { $0.id == id }) {
            let status = try? api.status(a.id)
            ListDetailPage(section: "Automations", onBack: { nav.close() }) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Chip(text: a.enabled ? "On" : "Off", tint: a.enabled ? .green : .gray)
                        if let approval = status?.approval {
                            Chip(text: approval == .rejected ? "Rejected" : "Needs approval", tint: approval == .rejected ? .red : .orange)
                        }
                    }
                    Text(a.name).font(.system(size: 24, weight: .bold)).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("Show logs…") { showLogs(a.id) }
                        Button("Run now") { Task { _ = try? await api.runNow(a.id) } }
                        Button("Edit…") { editing = a }
                        Button("Delete", role: .destructive) { try? api.delete(a.id); nav.close() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardMaterial()
                CardSection(title: "Summary") {
                    SummaryRow(label: "Enabled", symbol: "power") {
                        Toggle("Enabled", isOn: Binding(get: { a.enabled }, set: { on in try? api.setEnabled(a.id, on) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    SummaryRow(label: "Schedule", symbol: "clock") { value(subtitle(a)) }
                    if let last = status?.lastRun {
                        Divider()
                        SummaryRow(label: "Last run", symbol: "arrow.clockwise") { value("\(last.outcome)\(last.output.isEmpty ? "" : ", \(last.output)")") }
                    }
                    if let approval = status?.approval {
                        Divider()
                        SummaryRow(label: "Approval", symbol: SharedSymbols.approval) { value(approval == .rejected ? "Rejected" : "Waiting for your approval") }
                        HStack(spacing: 6) {
                            Spacer()
                            Button("Review…") { reviewing = a }
                            Button("Approve") { try? api.approve(a.id); tick += 1 }.buttonStyle(.borderedProminent)
                            if approval != .rejected { Button("Reject") { try? api.reject(a.id); tick += 1 } }
                        }
                        .controlSize(.small)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                    }
                    Divider()
                    SummaryRow(label: "Runs", symbol: "play") { value(a.action.type == "prompt" ? "A prompt for the pet" : a.action.type) }
                    Divider()
                    SummaryRow(label: "Created by", symbol: "person") { value(a.createdBy) }
                }
                if let hint = setupHint(a) {
                    Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).cardMaterial()
                }
            }
            .onExitCommand { nav.close() }
        } else {
            Color.clear.onAppear { nav.close() }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).multilineTextAlignment(.trailing).textSelection(.enabled)
    }

    /// A line of explanation under a card.
    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardSection(title: "Reminders") { switchRow("Pause all reminders", isOn: binding(\.paused)) }
                footer("A reminder on keyboard time only counts while you're at the keyboard. While a pet is working it can come a little early so you take the break while you'd be waiting anyway. Pets can add and change automations; anything that runs a command or a prompt waits for your Approve first.")
                CardSection(title: "Automations") {
                    if api.automations.isEmpty { Text("None yet. Ask a pet, or add one.").foregroundStyle(.secondary).padding(14) }
                    else if shown.isEmpty { Text("No automation has that text in its name or schedule.").foregroundStyle(.secondary).padding(14) }
                    ForEach(shown) { automation in
                        if automation.id != shown.first?.id { Divider() }
                        row(automation)
                    }
                    Divider()
                    HStack {
                        Button("New automation…") { asking = true }
                        Button("Show logs") { showLogs(nil) }
                        Button("Open automations.json") { NSWorkspace.shared.open(api.file) }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                CardSection(title: "Approval") {
                    switchRow("Auto-approve automation changes", isOn: Binding(
                        get: { config.config.automations.autoApprove },
                        set: { on in
                            config.update { $0.automations.autoApprove = on }
                            if on { api.reviewApprovals() }
                        }))
                }
                footer("Scripts a pet writes can run shell commands without review.")
                CardSection(title: "Failures") {
                    switchRow("Ask the pet to fix automations that fail", isOn: Binding(
                        get: { config.config.automations.autoFix },
                        set: { on in config.update { $0.automations.autoFix = on } }))
                }
                footer("When a poll, script, shell command or prompt fails, ironpet sends the error to the current chat and asks your pet to fix it with the automation tools. Changes to a command, script or prompt still wait for your Approve. At most one request per automation every 6 hours, and only after it has run fine since the last one.")
                CardSection(title: "Timing") {
                    SummaryRow(label: "Reset after being away", symbol: "moon.zzz", labelWidth: 200) { minutes(binding(\.idleResetMinutes), range: 1...60) }
                    Divider()
                    SummaryRow(label: "Snooze for", symbol: "bell.slash", labelWidth: 200) { minutes(binding(\.snoozeMinutes), range: 1...120) }
                    Divider()
                    SummaryRow(label: "Keep logs for", symbol: "tray.full", labelWidth: 200) {
                        Stepper(value: Binding(get: { config.config.automations.logRetentionDays },
                                               set: { days in config.update { $0.automations.logRetentionDays = days } }), in: 1...365, step: 1) {
                            Text("\(config.config.automations.logRetentionDays) day\(config.config.automations.logRetentionDays == 1 ? "" : "s")")
                                .monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                        }
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, ListScreenMetrics.gutter + 4)
            .padding(.vertical, 14)
        }
    }

    private func row(_ a: Automation) -> some View {
        // The next run, last run and approval state live in the service, not in observed state, so `tick` redraws the
        // row every 5 s. It must not become the row's id: that rebuilds the time picker and drops its focus mid-edit.
        let _ = tick
        return HStack(alignment: .top, spacing: 10) {
            Toggle(a.name, isOn: Binding(get: { a.enabled }, set: { on in try? api.setEnabled(a.id, on) }))
                .labelsHidden().toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    Text(a.name)
                    Text(subtitle(a)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { nav.open(a.id) }
                if DailySchedule.time(of: a.trigger) != nil { schedule(a) }
                if let last = (try? api.status(a.id))?.lastRun {
                    Text("Last: \(last.outcome)\(last.output.isEmpty ? "" : ", \(last.output)")")
                        .font(.caption).foregroundStyle(last.outcome == "failed" ? Color.red : Color.secondary).lineLimit(2)
                }
                if let hint = setupHint(a) {
                    Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                if let approval = (try? api.status(a.id))?.approval {
                    let rejected = approval == .rejected
                    Label(rejected ? "Rejected" : "Waiting for your approval", systemImage: rejected ? SharedSymbols.removeAttachment : SharedSymbols.approval)
                        .font(.caption).foregroundStyle(rejected ? Color.red : Color.orange)
                    HStack(spacing: 6) {
                        Button("Review…") { reviewing = a }
                        Button("Approve") { try? api.approve(a.id); tick += 1 }.buttonStyle(.borderedProminent)
                        if !rejected { Button("Reject") { try? api.reject(a.id); tick += 1 } }
                    }
                    .controlSize(.small).padding(.top, 2)
                }
            }
            Spacer()
            Menu {
                Button("Show logs…") { showLogs(a.id) }
                Button("Run now") { Task { _ = try? await api.runNow(a.id) } }
                Button("Edit…") { editing = a }
                Divider()
                Button("Delete", role: .destructive) { try? api.delete(a.id) }
            } label: { Image(systemName: SharedSymbols.more) }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// The time of a daily automation with one time, and Weekdays only when its days are every day or Monday to Friday.
    private func schedule(_ a: Automation) -> some View {
        HStack(spacing: 12) {
            DatePicker("Time", selection: Binding(
                get: { DailySchedule.time(of: a.trigger) ?? Date() },
                set: { date in try? api.setSchedule(SetAutomationScheduleRequest(id: a.id, times: [DailySchedule.format(date)])) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel("\(a.name) time")
            if let weekdaysOnly = DailySchedule.weekdaysOnly(a.trigger) {
                Toggle("Weekdays only", isOn: Binding(
                    get: { weekdaysOnly },
                    set: { on in
                        let days = DailySchedule.weekdays(only: on)
                        try? api.setSchedule(SetAutomationScheduleRequest(id: a.id, weekdays: days, everyDay: days == nil))
                    }))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("\(a.name) weekdays only")
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    /// What a default alert needs before it can report anything.
    private func setupHint(_ a: Automation) -> String? {
        guard a.enabled else { return nil }
        switch a.id {
        case AutomationDefaults.githubID: return AutomationDefaults.ghExecutable == nil ? "Needs the GitHub CLI: brew install gh, then gh auth login." : nil
        case AutomationDefaults.sentryID: return AutomationDefaults.sentryConfigured ? nil : "Not set up yet. Run ./scripts/configure_sentry.sh, which keeps the token in your Keychain."
        default: return nil
        }
    }

    private func subtitle(_ a: Automation) -> String {
        let status = try? api.status(a.id)
        var text = status?.trigger ?? ""
        if a.enabled, let next = status?.nextRun {
            text += " · next " + (a.trigger.type == "interval" && a.trigger.clock != "wall" ? "after about " : "") + Self.relative.localizedString(for: next, relativeTo: Date())
        }
        if a.trigger.type == "stream", a.enabled {
            text += " · " + (status?.stream ?? "")
            if let last = status?.lastEvent { text += ", last event " + Self.relative.localizedString(for: last, relativeTo: Date()) }
        }
        if a.createdBy != "user" { text += " · by \(a.createdBy)" }
        return text
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func binding<T>(_ path: WritableKeyPath<Config.Reminders, T>) -> Binding<T> {
        Binding(get: { config.config.reminders[keyPath: path] }, set: { value in config.update { $0.reminders[keyPath: path] = value } })
    }

    private func minutes(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 5) {
            Text("\(Int(value.wrappedValue)) min").monospacedDigit().frame(minWidth: 56, alignment: .trailing)
        }
        .fixedSize()
    }
}

/// Shows what an automation would run, so the user reads it before pressing Approve.
private struct ReviewSheet: View {
    @ObservedObject var api: AutomationsAPI
    let opened: Automation
    let done: () -> Void

    /// The stored automation, so an edit made while the sheet is open is what the user reads and approves.
    private var automation: Automation { api.automations.first { $0.id == opened.id } ?? opened }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow \(automation.name)?").font(.headline)
            Text("Created by \(automation.createdBy). It wants to run this \(automation.action.type == "prompt" ? "prompt" : "command"):")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text((try? api.approvalDetail(automation.id)) ?? "")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .frame(minHeight: 180, maxHeight: 360)
            .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Close", action: done)
                if (try? api.status(automation.id))?.approval != .rejected { Button("Reject") { try? api.reject(automation.id); done() } }
                Button("Approve") { try? api.approve(automation.id); done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}

private struct EditSheet: View {
    let api: AutomationsAPI
    let automation: Automation
    let done: () -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit \(automation.name)").font(.headline)
            Text("The automation as JSON. Fields are described in automations.schema.json next to automations.json.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 260)
                .border(Color.secondary.opacity(0.3))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Save") {
                    do { try api.replace(id: automation.id, definition: text); done() } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { text = (try? api.definition(automation.id)) ?? "" }
    }
}

/// The box behind "New automation…": the user says what they want, and the message goes to the chat for the agent to build it.
private struct NewAutomationSheet: View {
    let done: (String?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What kind of automation do you want?").font(.headline)
            Text("Say it in your own words. Your pet creates it with the automation tools and tells you what it made. For example: remind me to stretch every 45 minutes, tell me when CI fails on one of my PRs, or every weekday at 17:30 ask the pet to summarize what I changed today.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                Button("Ask the pet") { done(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

/// The inline schedule editor's mapping between a daily trigger and the time picker.
enum DailySchedule {
    /// Today at the trigger's time, for a daily trigger with exactly one valid time. Nil hides the picker.
    static func time(of trigger: Automation.Trigger, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard trigger.type == "daily", let times = trigger.times, times.count == 1,
              let minutes = AutomationClock.minutes(of: times[0]) else { return nil }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now)
    }

    /// "09:05".
    static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// True for Monday to Friday, false for every day, nil for any other set of days, which the toggle would lose.
    static func weekdaysOnly(_ trigger: Automation.Trigger) -> Bool? {
        guard let days = trigger.weekdays else { return false }
        if Set(days) == Set(AutomationDefaults.weekdays) { return true }
        if Set(days) == Set(AutomationValidator.weekdays) { return false }
        return nil
    }

    static func weekdays(only: Bool) -> [String]? { only ? AutomationDefaults.weekdays : nil }
}
