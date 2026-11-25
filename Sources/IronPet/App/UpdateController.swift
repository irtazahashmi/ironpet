import AppKit
import IronPetCore
import Sparkle

/// Keeps the app up to date through Sparkle. Sparkle finds, downloads, verifies (EdDSA signature against `SUPublicEDKey`) and
/// installs; this class decides whether it may run at all (`UpdatePolicy`), holds a ready update back while ironpet is busy, and
/// tells the pet and the user when one is waiting.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum State: Equatable {
        /// Updates are off for this build, with the reason shown in Settings.
        case off(String)
        case idle
        case checking
        /// A downloaded update waits for a quiet moment or a click.
        case ready(version: String)
        case failed(String)
    }

    /// The environment variable that points a dev or debug build at a local appcast, so an update can be tried without a release.
    static let feedOverrideVariable = "IRONPET_APPCAST_URL"

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    let appVersion: AppVersion
    /// What is running right now. Set by the app delegate.
    var activity: () -> UpdatePolicy.Activity = { UpdatePolicy.Activity() }
    /// The schema version of the database on this Mac.
    var localSchemaVersion: () -> Int = { 0 }
    /// Called whenever `state` changes, so the pet can show or clear its badge.
    var onStateChange: (() -> Void)?
    /// Called once when an update becomes ready and ironpet has to wait, to show a bubble and a notification.
    var onReadyAndWaiting: ((_ version: String, _ busy: String?) -> Void)?

    private let overrideFeed: URL?
    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    /// Sparkle's own callback that installs the downloaded update and relaunches. Kept until the update is installed.
    private var installHandler: (() -> Void)?
    private var idleTimer: Timer?

    /// `SUPublicEDKey` from Info.plist. Sparkle rejects every update whose signature does not verify against it.
    private let publicKey: String?

    init(appVersion: AppVersion = AppVersion(info: Bundle.main.infoDictionary),
         publicKey: String? = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.appVersion = appVersion
        self.publicKey = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Release builds ignore the override: a feed chosen by an environment variable is for testing only.
        let allowed = appVersion.isDev
        self.overrideFeed = allowed ? environment[Self.feedOverrideVariable].flatMap { URL(string: $0) } : nil
        super.init()
    }

    /// The feed a dev or debug build was pointed at, or nil to use `SUFeedURL` from Info.plist.
    var feedOverride: String? { overrideFeed?.absoluteString }

    var disabledReason: String? {
        UpdatePolicy.disabledReason(version: appVersion, overrideFeed: overrideFeed, hasPublicKey: !(publicKey ?? "").isEmpty)
    }

    /// Starts Sparkle, unless this build must not update. A dev build never creates the updater, so nothing is checked or installed.
    func start(config: Config.Updates) {
        if let reason = disabledReason {
            state = .off(reason)
            return
        }
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        userDriver = driver
        self.updater = updater
        apply(config)
        do {
            try updater.start()
        } catch {
            state = .failed(error.localizedDescription)
            NSLog("ironpet: updates could not start: \(error)")
        }
    }

    /// Applies the two switches from Settings. Sparkle keeps its own copy in UserDefaults, which this overwrites at every change.
    func apply(_ config: Config.Updates) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = config.checkAutomatically
        updater.automaticallyDownloadsUpdates = config.checkAutomatically && config.installAutomatically
    }

    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    /// "Check now": Sparkle shows its own window with the version, the release notes and Install Update.
    func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        state = .checking
        updater.checkForUpdates()
    }

    /// The user chose the moment: install and restart, even if something is running.
    func installNow() {
        guard let handler = installHandler else { return }
        installHandler = nil
        handler()
    }

    var isReady: Bool { if case .ready = state { return true } else { return false } }

    // MARK: Deferral

    private func set(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?()
    }

    /// Holds the update until `UpdatePolicy` says it is safe, checking again every 30 seconds. A click calls `installNow` instead.
    private func waitForQuietMoment(version: String) {
        let busy = UpdatePolicy.busyReason(activity())
        set(.ready(version: version))
        onReadyAndWaiting?(version, busy)
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() } // the timer is scheduled on the main run loop
        }
    }

    func installIfQuiet() {
        guard isReady, UpdatePolicy.mayInstallNow(activity(), userApproved: false) else { return }
        idleTimer?.invalidate()
        installNow()
    }

    // MARK: SPUUpdaterDelegate

    /// Settings → General → Updates is where the user chooses, so Sparkle never asks on its own.
    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedOverride } // Sparkle calls its delegate on the main thread
    }

    /// The downgrade guard. Sparkle only offers versions newer than the running one, but a build that is newer by number can
    /// still carry an older database schema (a release rebuilt from an older branch). Installing it would leave the newer
    /// database unreadable, so it is refused with a message instead.
    nonisolated func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        let refusal: String? = MainActor.assumeIsolated { // Sparkle calls its delegate on the main thread
            let schema = (updateItem.propertiesDictionary["ironpet:schemaVersion"] as? String).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return UpdatePolicy.downgradeRefusal(updateSchema: schema, localSchema: localSchemaVersion(), updateVersion: updateItem.displayVersionString)
        }
        if let refusal { throw NSError(domain: "dev.ironpet.update", code: 1, userInfo: [NSLocalizedDescriptionKey: refusal]) }
    }

    /// An update that downloaded in the background and would install when the app quits. ironpet takes over: it installs when idle
    /// or on a click, and never in the middle of a turn or a recording.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { // Sparkle calls its delegate on the main thread
            installHandler = immediateInstallHandler
            waitForQuietMoment(version: item.displayVersionString)
        }
        return true
    }

    /// An update the user accepted in Sparkle's window. If something is running, Sparkle waits for `installHandler`.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { // Sparkle calls its delegate on the main thread
            guard UpdatePolicy.busyReason(activity()) != nil else { return false }
            self.installHandler = installHandler
            waitForQuietMoment(version: item.displayVersionString)
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated { // Sparkle calls its delegate on the main thread
            lastChecked = Date()
            if isReady { return }
            if let error, (error as NSError).code != 1001 /* SUNoUpdateError */ {
                set(.failed(error.localizedDescription))
            } else {
                set(.idle)
            }
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { if !isReady { set(.idle) } } // Sparkle calls its delegate on the main thread
    }
}
