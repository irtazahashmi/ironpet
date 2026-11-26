import IronPetCore
import SwiftUI

/// Settings → Inbox: the scan that adds items from chats and screen text.
struct InboxSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = SettingsAPI.live

    var body: some View {
        let tasks = store.config.tasks
        Form {
            Section {
                Toggle("Scan for things to add to the Inbox", isOn: Binding(
                    get: { tasks.inboxScan }, set: { on in store.update { $0.tasks.inboxScan = on } }))
                Stepper {
                    Text("Scan every \(Self.interval(tasks.inboxScanMinutes))")
                } onIncrement: {
                    let m = tasks.inboxScanMinutes
                    store.update { $0.tasks.inboxScanMinutes = min(Config.Tasks.inboxScanMinutesRange.upperBound, m < 60 ? m + 15 : m + 60) }
                } onDecrement: {
                    let m = tasks.inboxScanMinutes
                    store.update { $0.tasks.inboxScanMinutes = max(Config.Tasks.inboxScanMinutesRange.lowerBound, m > 60 ? m - 60 : m - 15) }
                }
                .disabled(!tasks.inboxScan)
                Toggle("Read screen text", isOn: Binding(
                    get: { tasks.inboxScanScreen }, set: { on in store.update { $0.tasks.inboxScanScreen = on } }))
                    .disabled(!tasks.inboxScan || (!store.config.screenCapture.enabled && !tasks.inboxScanScreen))
                    .help("Also reads the text of the screen captures that screen capture saves. Needs screen capture to be on.")
                Toggle("Show bubbles", isOn: Binding(
                    get: { tasks.inboxScanBubbles }, set: { on in store.update { $0.tasks.inboxScanBubbles = on } }))
                    .disabled(!tasks.inboxScan)
            } footer: {
                Text("Each scan sends the chat messages that are new to the agent of that chat, and the screen text that is new to the agent of the current chat. An item already in the Inbox is not added again, and one you removed does not come back. Apps on the screen capture skip list and secure fields are never read. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static func interval(_ minutes: Int) -> String {
        guard minutes >= 60, minutes % 60 == 0 else { return "\(minutes) min" }
        return minutes == 60 ? "hour" : "\(minutes / 60) hours"
    }
}
