import IronPetKit
import SwiftUI

struct SettingsView: View {
    let app: AppModel
    let client: IronPetClient
    @State private var device: RemoteDevice?
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("This device") {
                        LabeledContent("Name", value: device?.name ?? "…")
                        if let seen = device?.lastSeen { LabeledContent("Last seen", value: seen.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    Section("Mac") {
                        LabeledContent("Address", value: client.endpoint.baseURL.absoluteString)
                        LabeledContent("Certificate", value: client.endpoint.pin == nil ? "Standard validation" : "Pinned")
                    }
                    Section {
                        Button("Unpair this device", role: .destructive) { confirming = true }.accessibilityIdentifier("unpair-button")
                    } footer: {
                        Text("The Mac forgets this device and the token is deleted from the Keychain.")
                    }
            
                }.listRowBackground(SharedTheme.card)
            }
            .navigationTitle("Device")
            .themedScreen()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("device-done") } }
            .confirmationDialog("Unpair from this Mac?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { Task { await app.unpair() } }
            }
            .task {
                do { device = try await client.device() } catch ClientError.unauthorized { app.handleUnauthorized() } catch {}
            }
        }
    }
}
