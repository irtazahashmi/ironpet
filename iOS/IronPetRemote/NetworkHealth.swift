import Foundation
import IronPetKit
import Network
import Observation

/// What the phone knows about its connection to the Mac. Every read and write reports here, so there is one answer to "can the phone
/// reach the Mac", and the status strip, the full-page error and the reload after a reconnect all follow it.
@MainActor @Observable
final class NetworkHealth {
    /// A problem only the person can fix, shown once as a sheet with an action.
    enum Problem: String, Identifiable, Equatable {
        case pairingExpired, macTooOld
        var id: String { rawValue }
    }

    /// How long the connection stays down before the strip shows. A shorter drop shows nothing, because the outbox buffers and syncs.
    @ObservationIgnored var stripDelay: Duration
    /// The wait between the tries of one read. Tests shorten it.
    @ObservationIgnored var retryPolicy: RetryPolicy = NetworkHealth.defaultRetryPolicy

    /// The unit tests run inside this app and stop the mock Mac on purpose. A real 1 s, 2 s backoff would make each of them seconds slower
    /// and their timing tighter, so under XCTest the wait is a few milliseconds. The UI tests run the app as its own process and use the real policy
    /// unless they pass `--network-retry-ms`.
    private static var defaultRetryPolicy: RetryPolicy {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? .standard
            : RetryPolicy(attempts: 3, base: .milliseconds(10), maxDelay: .milliseconds(40))
    }
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleeper: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Called once each time the network path comes back. The app points it at the event socket's `reconnectNow`, so the socket does not
    /// sit out a back-off of up to 30 s while the network is already there.
    @ObservationIgnored var onPathReturned: (() -> Void)?

    /// When requests started failing, or nil while they work.
    private(set) var failingSince: Date?
    /// The last time any request got an answer from the Mac.
    private(set) var lastSync: Date?
    /// The strip is on screen. It is true only after `stripDelay` of failures and clears with the first answer.
    private(set) var stripVisible = false
    /// False while the phone has no network at all, which changes the strip's wording.
    private(set) var pathSatisfied = true
    var problem: Problem?
    /// Problems the person already saw this launch, so one is not shown again after every failed read.
    @ObservationIgnored private var shown: Set<Problem> = []

    init(stripDelay: Duration = .seconds(10), now: @escaping () -> Date = Date.init,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.stripDelay = stripDelay
        self.now = now
        self.sleeper = sleep
    }

    /// The strip's first line.
    var stripTitle: String { pathSatisfied ? "Can't reach your Mac" : "Offline, changes will sync" }

    /// "Updated 5 min ago", or nil before the first answer.
    func updatedText(at date: Date? = nil) -> String? {
        guard let lastSync else { return nil }
        let seconds = Int((date ?? now()).timeIntervalSince(lastSync))
        switch seconds {
        case ..<60: return "Updated just now"
        case ..<3600: return "Updated \(seconds / 60) min ago"
        case ..<86400: return "Updated \(seconds / 3600) h ago"
        default: return "Updated \(seconds / 86400) d ago"
        }
    }

    /// The wait the shared client puts between two tries.
    var sleep: @Sendable (Duration) async throws -> Void { sleeper }

    // MARK: Reports

    /// The Mac answered, with data or with an error of its own.
    /// `announce` is false for the event socket opening: its own signal already makes every screen read, so a second reload would double the reads.
    func reportAnswered(announce: Bool = true) {
        lastSync = now()
        guard failingSince != nil else { return }
        failingSince = nil
        stripVisible = false
        timer?.cancel()
        timer = nil
        if announce { announceReconnect() }
    }

    /// A request ended in `error`. Only a failure to reach the Mac counts as down; an answer from the Mac does not.
    func report(_ error: Error) {
        if RequestRetry.isTransient(error) { reportUnreachable() } else { reportAnswered() }
    }

    func reportUnreachable() {
        guard failingSince == nil else { return }
        failingSince = now()
        timer?.cancel()
        let delay = stripDelay
        timer = Task { [weak self] in
            try? await self?.sleeper(delay)
            guard !Task.isCancelled, let self, self.failingSince != nil else { return }
            self.stripVisible = true
        }
    }

    /// Shows a one-time sheet unless this launch already did.
    func raise(_ next: Problem) {
        guard !shown.contains(next) else { return }
        shown.insert(next)
        problem = next
    }

    // MARK: Reconnect

    /// Fires once each time the connection comes back, so every started screen reads again without a pull to refresh.
    func reconnects() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        }
    }

    private func announceReconnect() {
        for continuation in subscribers.values { continuation.yield() }
    }

    /// The system's own reachability: the strip says "Offline" when the phone has no network, and a network that returns reloads at once.
    func startPathMonitor() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.setPath(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "network-health"))
    }

    func stopPathMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    func setPath(satisfied: Bool) {
        let returned = satisfied && !pathSatisfied
        pathSatisfied = satisfied
        if !satisfied { reportUnreachable() }
        if returned {
            onPathReturned?()
            announceReconnect()
        }
    }
}
