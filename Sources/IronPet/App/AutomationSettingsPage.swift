import IronPetCore
import SwiftUI

/// Settings → Automations: the approval, failure and timing settings that apply to every automation.
/// The automations themselves are in the main window's Automations section.
struct AutomationSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = SettingsAPI.live

    var body: some View {
        Form {
            Section {
                Toggle("Auto-approve automation changes", isOn: Binding(
                    get: { store.config.automations.autoApprove },
                    set: { on in
                        store.update { $0.automations.autoApprove = on }
                        if on { model.automations?.reviewApprovals() }
                    }))
            } header: {
                Text("Approval")
            } footer: {
                Text("Scripts a pet writes can run shell commands without review. A command, script or prompt a pet writes waits for your Approve first, unless auto-approve is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ask the pet to fix automations that fail", isOn: Binding(
                    get: { store.config.automations.autoFix },
                    set: { on in store.update { $0.automations.autoFix = on } }))
            } header: {
                Text("Failures")
            } footer: {
                Text("When a poll, script, shell command or prompt fails, ironpet sends the error to the current chat and asks your pet to fix it with the automation tools. Changes to a command, script or prompt still wait for your Approve. At most one request per automation every 6 hours, and only after it has run fine since the last one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Timing") {
                LabeledContent("Reset after being away") { minutes(\.idleResetMinutes, range: 1...60) }
                LabeledContent("Snooze for") { minutes(\.snoozeMinutes, range: 1...120) }
                LabeledContent("Keep logs for") {
                    let days = store.config.automations.logRetentionDays
                    Stepper(value: Binding(get: { days }, set: { value in store.update { $0.automations.logRetentionDays = value } }),
                            in: 1...365, step: 1) {
                        Text("\(days) day\(days == 1 ? "" : "s")").monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func minutes(_ path: WritableKeyPath<Config.Reminders, Double>, range: ClosedRange<Double>) -> some View {
        let value = Binding(get: { store.config.reminders[keyPath: path] }, set: { v in store.update { $0.reminders[keyPath: path] = v } })
        return Stepper(value: value, in: range, step: 5) {
            Text("\(Int(value.wrappedValue)) min").monospacedDigit().frame(minWidth: 56, alignment: .trailing)
        }
        .fixedSize()
    }
}
