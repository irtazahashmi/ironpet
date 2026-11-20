import Foundation
import IronPetKit
import Observation

@MainActor @Observable
final class PairingModel {
    enum State: Equatable {
        case idle
        case connecting
        /// The Mac shows "Allow <device>?".
        case waiting
        case denied
        case failed(String)
    }

    var linkText = ""
    private(set) var state: State = .idle
    @ObservationIgnored var pollInterval: Duration = .seconds(1)
    @ObservationIgnored let deviceName: String
    @ObservationIgnored let onPaired: (PairedDevice) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(deviceName: String, onPaired: @escaping (PairedDevice) -> Void) {
        self.deviceName = deviceName
        self.onPaired = onPaired
    }

    var isBusy: Bool { state == .connecting || state == .waiting }

    func submit(_ text: String) {
        guard !isBusy else { return }
        let link: PairingLink
        do { link = try PairingLink(parsing: text) } catch {
            state = .failed("This is not an IronPet pairing link. It starts with ironpet://pair.")
            return
        }
        state = .connecting
        let flow = PairingFlow(link: link, deviceName: deviceName, pollInterval: pollInterval)
        task = Task { [weak self] in
            do {
                let device = try await flow.run { Task { @MainActor in self?.markWaiting() } }
                self?.finish(device)
            } catch is CancellationError {
                self?.state = .idle
            } catch ClientError.pairingDenied {
                self?.state = .denied
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private func markWaiting() { if state == .connecting { state = .waiting } }

    private func finish(_ device: PairedDevice) {
        task = nil
        state = .idle
        linkText = ""
        onPaired(device)
    }
}
