import IronPetKit
import SwiftUI
import UIKit

struct PairingView: View {
    let app: AppModel
    @State private var pairing: PairingModel
    @State private var scanning = false

    init(model: AppModel) {
        app = model
        _pairing = State(initialValue: PairingModel(deviceName: UIDevice.current.name, onPaired: { [weak model] device in model?.completePairing(device) }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On your Mac, open IronPet, go to Settings, then Devices, and show the pairing code. Scan it here or paste the link.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let notice = app.notice {
                        Text(notice).foregroundStyle(.orange).accessibilityIdentifier("pairing-notice")
                    }
                }
                Section("Scan") {
                    Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                        .disabled(pairing.isBusy)
                        .accessibilityIdentifier("scan-button")
                }
                Section("Paste pairing link") {
                    TextField("ironpet://pair?u=…", text: $pairing.linkText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("pairing-link-field")
                    Button("Pair") { pairing.submit(pairing.linkText) }
                        .disabled(pairing.linkText.trimmingCharacters(in: .whitespaces).isEmpty || pairing.isBusy)
                        .accessibilityIdentifier("pair-button")
                }
                Section { status }
            }
            .navigationTitle("IronPet")
            .sheet(isPresented: $scanning) {
                ScannerSheet { code in
                    scanning = false
                    pairing.linkText = code
                    pairing.submit(code)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch pairing.state {
        case .idle:
            EmptyView()
        case .connecting:
            HStack { ProgressView(); Text("Contacting your Mac") }.accessibilityIdentifier("pairing-status")
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                HStack { ProgressView(); Text("Waiting for Allow on your Mac") }
                Button("Cancel", role: .cancel) { pairing.cancel() }
            }.accessibilityIdentifier("pairing-status")
        case .denied:
            Label("The Mac denied this device.", systemImage: "xmark.octagon").foregroundStyle(.red).accessibilityIdentifier("pairing-denied")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("pairing-error")
        }
    }
}
