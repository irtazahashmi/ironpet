import Foundation
import IronPetKit
import Observation

/// Paired or not. Every screen that gets a 401 calls `handleUnauthorized`, which deletes the token and shows pairing again.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case unpaired
        case paired(PairedDevice)
    }

    private(set) var phase: Phase
    /// A line for the pairing screen, such as why the app is back there.
    var notice: String?
    /// Set when the Mac stopped accepting this phone. The pairing screen shows it once as a sheet with the one action that fixes it.
    var problem: NetworkHealth.Problem?
    @ObservationIgnored let store: CredentialStore
    /// Where the event socket keeps the last event it applied. Pairing or unpairing forgets it.
    @ObservationIgnored private let resumeDefaults: UserDefaults

    init(store: CredentialStore, resumeDefaults: UserDefaults = .standard) {
        self.store = store
        self.resumeDefaults = resumeDefaults
        if let device = store.load() { phase = .paired(device) } else { phase = .unpaired }
    }

    var device: PairedDevice? {
        if case .paired(let device) = phase { return device }
        return nil
    }

    func completePairing(_ device: PairedDevice) {
        do {
            // A resume point from the Mac paired before is no use to this one.
            DefaultsResumeStore.clearAll(defaults: resumeDefaults)
            try store.save(device)
            notice = nil
            phase = .paired(device)
        } catch {
            notice = error.localizedDescription
        }
    }

    func handleUnauthorized() {
        guard device != nil else { return }
        store.delete()
        DefaultsResumeStore.clearAll(defaults: resumeDefaults)
        forgetPresence()
        notice = "The Mac no longer accepts this device. Pair it again."
        problem = .pairingExpired
        phase = .unpaired
    }

    /// Tells the Mac to forget this device, then forgets the token whatever the Mac answered.
    func unpair() async {
        if let device {
            try? await IronPetClient(endpoint: device.endpoint, token: device.token).revokeSelf()
        }
        store.delete()
        DefaultsResumeStore.clearAll(defaults: resumeDefaults)
        forgetPresence()
        notice = nil
        phase = .unpaired
    }

    /// Drops the Home Screen widget snapshot and any Live Activity so an unpaired phone shows nothing private.
    private func forgetPresence() {
        PetSnapshotStore.clear()
        PetPresence.endAll()
    }
}
