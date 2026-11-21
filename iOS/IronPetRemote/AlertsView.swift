import IronPetKit
import SwiftUI

/// Alerts. The More tab owns the navigation stack, so this is only the list.
struct AlertsView: View {
    let model: AlertsModel
    @State private var confirming = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("alerts-error")
            }
            if let notice = model.notice {
                Label(notice, systemImage: "paperplane").accessibilityIdentifier("alerts-notice")
            }
            ForEach(model.alerts) { alert in
                VStack(alignment: .leading, spacing: 6) {
                    Label(alert.label.isEmpty ? alert.title : alert.label, systemImage: alert.symbol)
                        .font(.caption).foregroundStyle(alert.mood == "failed" ? .red : .orange)
                    Text(alert.title).font(.headline)
                    if !alert.subtitle.isEmpty { Text(alert.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    HStack {
                        if let link = alert.url.flatMap(URL.init(string:)) { Button("Open") { openURL(link) }.accessibilityIdentifier("open-\(alert.id)") }
                        if alert.canAsk { Button("Ask Ghost") { Task { await model.ask(alert) } }.accessibilityIdentifier("ask-\(alert.id)") }
                        Button("Dismiss", role: .destructive) { Task { await model.dismiss(alert) } }.accessibilityIdentifier("dismiss-\(alert.id)")
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("alert-\(alert.id)")
                .swipeActions { Button("Dismiss", role: .destructive) { Task { await model.dismiss(alert) } } }
            }
            if model.loaded, model.alerts.isEmpty {
                ContentUnavailableView("No alerts", systemImage: "bell", description: Text("What your automations report shows up here."))
            }
        }
        .navigationTitle("Alerts")
        .refreshable { await model.refresh() }
        .toolbar {
            if !model.alerts.isEmpty {
                Button("Dismiss all") { confirming = true }.accessibilityIdentifier("dismiss-all-button")
            }
        }
        .confirmationDialog("Dismiss all \(model.alerts.count) alerts?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Dismiss all", role: .destructive) { Task { await model.dismissAll() } }
        }
        .task { model.start() }
    }
}
