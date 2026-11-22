import IronPetKit
import SwiftUI
import UIKit

struct PairingView: View {
    @Environment(\.macAccent) private var macAccent
    let app: AppModel
    @State private var pairing: PairingModel
    @State private var scanning = false

    init(model: AppModel) {
        app = model
        _pairing = State(initialValue: PairingModel(deviceName: UIDevice.current.name, onPaired: { [weak model] device in model?.completePairing(device) }))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    if let notice = app.notice {
                        Text(notice).font(.subheadline).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .chromeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityIdentifier("pairing-notice")
                    }
                    steps
                    actions
                    status
                }
                .padding()
            }
            .navigationTitle("IronPet")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanning) {
                ScannerSheet { code in
                    scanning = false
                    pairing.linkText = code
                    pairing.submit(code)
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 96, height: 96)
                .chromeGlass(in: Circle())
                .accessibilityHidden(true)
            Text("Your Mac's pet, on your phone")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Pair once, then check moods, chat, tasks and alerts from anywhere on your network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pairing-hero")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On your Mac").font(.headline)
            step(1, "Open IronPet → Settings → Devices")
            step(2, "Show the pairing code")
            step(3, "Scan it here, or paste the link below")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .chromeGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("pairing-steps")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(macAccent.opacity(0.15), in: Circle())
                .foregroundStyle(macAccent)
            Text(text).font(.subheadline)
        }
    }

    private var actions: some View {
        VStack(spacing: 16) {
            Button { scanning = true } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairing.isBusy)
            .accessibilityIdentifier("scan-button")

            VStack(alignment: .leading, spacing: 8) {
                Text("Or paste the pairing link").font(.subheadline.weight(.semibold))
                TextField("ironpet://pair?u=…", text: $pairing.linkText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1...4)
                    .padding(12)
                    .chromeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("pairing-link-field")
                Button("Pair") { pairing.submit(pairing.linkText) }
                    .frame(maxWidth: .infinity)
                    .disabled(pairing.linkText.trimmingCharacters(in: .whitespaces).isEmpty || pairing.isBusy)
                    .accessibilityIdentifier("pair-button")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch pairing.state {
        case .idle:
            EmptyView()
        case .connecting:
            statusCard {
                HStack { ProgressView(); Text("Contacting your Mac") }
            }
            .accessibilityIdentifier("pairing-status")
        case .waiting:
            statusCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { ProgressView(); Text("Waiting for Allow on your Mac") }
                    Button("Cancel", role: .cancel) { pairing.cancel() }
                }
            }
            .accessibilityIdentifier("pairing-status")
        case .denied:
            statusCard {
                Label("The Mac denied this device.", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            .accessibilityIdentifier("pairing-denied")
        case .failed(let message):
            statusCard {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            .accessibilityIdentifier("pairing-error")
        }
    }

    private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .chromeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
