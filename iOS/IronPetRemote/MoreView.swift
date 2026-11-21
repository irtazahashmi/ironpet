import IronPetKit
import SwiftUI

/// The fifth tab: the screens that do not need a tab of their own.
struct MoreView: View {
    let alerts: AlertsModel
    let automations: AutomationsModel
    let meetings: MeetingsModel
    let screen: ScreenModel
    let settings: PhoneSettingsModel
    @Binding var path: [MoreDestination]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: MoreDestination.alerts) {
                    HStack {
                        Label("Alerts", systemImage: "bell")
                        Spacer()
                        if !alerts.alerts.isEmpty { Text("\(alerts.alerts.count)").foregroundStyle(.secondary) }
                    }
                }
                .accessibilityIdentifier("more-alerts")
                NavigationLink(value: MoreDestination.automations) {
                    HStack {
                        Label("Automations", systemImage: "clock.arrow.2.circlepath")
                        Spacer()
                        let waiting = automations.automations.filter(\.waitsForApproval).count
                        if waiting > 0 { Text("\(waiting) waiting").foregroundStyle(.orange) }
                    }
                }
                .accessibilityIdentifier("more-automations")
                NavigationLink(value: MoreDestination.meetings) { Label("Meetings", systemImage: "person.2") }
                    .accessibilityIdentifier("more-meetings")
                NavigationLink(value: MoreDestination.screen) { Label("Screen", systemImage: "rectangle.dashed.badge.record") }
                    .accessibilityIdentifier("more-screen")
                NavigationLink(value: MoreDestination.settings) { Label("Settings", systemImage: "slider.horizontal.3") }
                    .accessibilityIdentifier("more-settings")
            }
            .navigationTitle("More")
            .navigationDestination(for: MoreDestination.self) { destination in
                switch destination {
                case .alerts: AlertsView(model: alerts)
                case .automations: AutomationsView(model: automations)
                case .meetings: MeetingsView(model: meetings)
                case .screen: ScreenView(model: screen)
                case .settings: PhoneSettingsView(model: settings)
                }
            }
        }
    }
}
