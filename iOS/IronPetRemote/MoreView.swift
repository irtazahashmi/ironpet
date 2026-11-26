import IronPetKit
import SwiftUI

/// The fifth tab: the screens that do not need a tab of their own.
struct MoreView: View {
    let alerts: AlertsModel
    let automations: AutomationsModel
    let meetings: MeetingsModel
    let memory: MemoryModel
    let screen: ScreenModel
    let settings: PhoneSettingsModel
    let phoneAgent: PhoneAgentModel
    @Binding var path: [MoreDestination]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    NavigationLink(value: MoreDestination.alerts) {
                        HStack {
                            Label("Alerts", systemImage: SharedSymbols.alerts)
                            Spacer()
                            if !alerts.alerts.isEmpty { Text("\(alerts.alerts.count)").foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("more-alerts")
                    NavigationLink(value: MoreDestination.automations) {
                        HStack {
                            Label("Automations", systemImage: SharedSymbols.automations)
                            Spacer()
                            let waiting = automations.automations.filter(\.waitsForApproval).count
                            if waiting > 0 { Text("\(waiting) waiting").foregroundStyle(.orange) }
                        }
                    }
                    .accessibilityIdentifier("more-automations")
                    NavigationLink(value: MoreDestination.meetings) { Label("Meetings", systemImage: SharedSymbols.meetings) }
                        .accessibilityIdentifier("more-meetings")
                    NavigationLink(value: MoreDestination.memory) { Label("Memory", systemImage: SharedSymbols.memory) }
                        .accessibilityIdentifier("more-memory")
                    NavigationLink(value: MoreDestination.screen) { Label("Screen", systemImage: SharedSymbols.screen) }
                        .accessibilityIdentifier("more-screen")
                    NavigationLink(value: MoreDestination.phoneAgent) {
                        HStack {
                            Label("Phone agent", systemImage: SharedSymbols.agents)
                            Spacer()
                            if !phoneAgent.waiting.isEmpty { Text("\(phoneAgent.waiting.count) waiting").foregroundStyle(.orange) }
                        }
                    }
                    .accessibilityIdentifier("more-phone-agent")
                    NavigationLink(value: MoreDestination.settings) { Label("Settings", systemImage: SharedSymbols.settings) }
                        .accessibilityIdentifier("more-settings")
            
                }.listRowBackground(SharedTheme.card)
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
            .navigationDestination(for: MoreDestination.self) { destination in
                switch destination {
                case .alerts: AlertsView(model: alerts)
                case .automations: AutomationsView(model: automations)
                case .meetings: MeetingsView(model: meetings)
                case .memory: MemoryView(model: memory)
                case .memoryPage(let id): MemoryPageView(model: memory, id: id)
                case .screen: ScreenView(model: screen)
                case .settings: PhoneSettingsView(model: settings)
                case .phoneAgent: PhoneAgentView(model: phoneAgent)
                }
            }
        }
    }
}
