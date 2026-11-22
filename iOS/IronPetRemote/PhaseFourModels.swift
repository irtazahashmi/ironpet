import Foundation
import IronPetKit
import LocalAuthentication
import Observation
import SwiftUI

// MARK: Automations

/// The Automations screen: the list, and the actions on one automation. Whatever runs a command, script or prompt and is new or changed
/// shows "Waiting for Approve on the Mac". The phone has no call that approves.
@MainActor @Observable
final class AutomationsModel: SocketModel {
    private(set) var automations: [RemoteAutomation] = []
    /// A line of feedback for the last action, such as the answer to "New automation…".
    var notice: String?

    override func reload() async {
        if let list = await run({ try await self.client.automations() }) { automations = list }
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.automationsChanged, RemoteEvent.automationNeedsApproval: await reload()
        default: break
        }
    }

    func setPaused(_ automation: RemoteAutomation, _ paused: Bool) async {
        let done: Void? = await run {
            if paused { try await self.client.pauseAutomation(id: automation.id) } else { try await self.client.resumeAutomation(id: automation.id) }
        }
        if done != nil { await reload() }
    }

    func runNow(_ automation: RemoteAutomation) async {
        if let result = await run({ try await self.client.runAutomation(id: automation.id) }) {
            notice = result.status == "started" ? "Started \(automation.name)." : "\(automation.name) is waiting for Approve on the Mac."
            await reload()
        }
    }

    func delete(_ automation: RemoteAutomation) async {
        let done: Void? = await run { try await self.client.deleteAutomation(id: automation.id) }
        if done != nil { await reload() }
    }

    func request(_ text: String) async -> Bool {
        let done: Void? = await run { try await self.client.requestAutomation(text) }
        if done != nil { notice = "Sent to Ghost. The answer is in the chat on your Mac." }
        return done != nil
    }

    /// Creates an automation from its JSON. Returns true when the Mac accepted it.
    func create(definition: String) async -> Bool {
        guard let made = await run({ try await self.client.createAutomation(definition: definition) }) else { return false }
        notice = made.waitsForApproval ? "\(made.name) waits for Approve on the Mac before it runs." : "Created \(made.name)."
        await reload()
        return true
    }

    func update(_ automation: RemoteAutomation, changes: String) async -> Bool {
        guard let changed = await run({ try await self.client.updateAutomation(id: automation.id, changes: changes) }) else { return false }
        notice = changed.waitsForApproval ? "\(changed.name) waits for Approve on the Mac before it runs." : "Saved \(changed.name)."
        await reload()
        return true
    }

    func detail(_ id: String) async -> RemoteAutomation? { await run { try await self.client.automation(id: id) } }
    func history(_ id: String) async -> [RemoteAutomationRun] { await run { try await self.client.automationHistory(id: id) } ?? [] }
    func log(_ id: String) async -> [RemoteAutomationLogEntry] { await run { try await self.client.automationLog(id: id) } ?? [] }
}

// MARK: Transcripts gate

/// Asks the person who holds the phone. `LocalAuthenticator` is Face ID or the passcode; tests pass their own.
protocol DeviceAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

struct LocalAuthenticator: DeviceAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Meetings stay locked until Face ID or the passcode says yes, and lock again after the app was in the background for five minutes.
/// Locking calls `onLock`, which drops the text from memory.
@MainActor @Observable
final class TranscriptGate {
    /// How long the app may sit in the background before the next look asks again.
    static let backgroundLimit: TimeInterval = 5 * 60

    private(set) var isUnlocked = false
    /// The last attempt was refused or cancelled.
    private(set) var refused = false
    @ObservationIgnored let authenticator: any DeviceAuthenticating
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored var onLock: () -> Void = {}
    /// What the system prompt says it is for.
    @ObservationIgnored let reason: String

    init(authenticator: any DeviceAuthenticating = LocalAuthenticator(), reason: String = "Show meeting transcripts", now: @escaping () -> Date = Date.init) {
        self.authenticator = authenticator
        self.reason = reason
        self.now = now
    }

    func unlock() async {
        guard !isUnlocked else { return }
        let ok = await authenticator.authenticate(reason: reason)
        refused = !ok
        isUnlocked = ok
        if ok { backgroundedAt = nil }
    }

    func lock() {
        guard isUnlocked else { return }
        isUnlocked = false
        onLock()
    }

    /// The one place that maps the scene phase to the gate, so MainTabs and the Meetings screen cannot disagree.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background: appMovedToBackground()
        case .active: appBecameActive()
        default: break
        }
    }

    func appMovedToBackground() { if isUnlocked, backgroundedAt == nil { backgroundedAt = now() } }

    func appBecameActive() {
        if let since = backgroundedAt, now().timeIntervalSince(since) >= Self.backgroundLimit { lock() }
        backgroundedAt = nil
    }
}

// MARK: Meetings

/// The Meetings screen. Nothing is read from the Mac while it is locked, and the text of a summary or transcript lives in this object
/// only: it is not written to disk, and locking drops it.
@MainActor @Observable
final class MeetingsModel: SocketModel {
    private(set) var meetings: [RemoteMeeting] = []
    private(set) var state = RemoteMeetingState()
    /// Summary and transcript text by `<meeting id>/<kind>`.
    private(set) var texts: [String: String] = [:]
    var notice: String?
    let gate: TranscriptGate

    /// "No meetings" is true only after a load that worked and found none. A failed load shows its error instead.
    var showsEmptyState: Bool { loaded && meetings.isEmpty && errorMessage == nil }

    init(client: IronPetClient, events: any EventSignalSource, gate: TranscriptGate? = nil, onUnauthorized: @escaping () -> Void) {
        let gate = gate ?? TranscriptGate()
        self.gate = gate
        super.init(client: client, events: events, onUnauthorized: onUnauthorized)
        gate.onLock = { [weak self] in self?.forget() }
    }

    /// Drops everything that came from the Mac.
    private func forget() {
        meetings = []
        texts = [:]
        notice = nil
        state = RemoteMeetingState()
    }

    func unlock() async {
        await gate.unlock()
        if gate.isUnlocked { await refresh() }
    }

    override func reload() async {
        guard gate.isUnlocked else { return }
        // `run` clears the error after a success, so a failed list must be kept past the state call that follows it.
        var failure: String?
        if let list = await run({ try await self.client.meetings() }) {
            if gate.isUnlocked { meetings = list }
        } else {
            failure = errorMessage
        }
        if let current = await run({ try await self.client.meetingState() }) {
            if gate.isUnlocked { state = current }
        } else {
            failure = failure ?? errorMessage
        }
        errorMessage = failure
    }

    override func handle(_ event: RemoteEvent) async {
        if event.kind == RemoteEvent.meetingsChanged { await reload() }
    }

    /// The summary or transcript of a meeting, or nil when it has none or the screen is locked.
    func text(_ id: String, _ kind: String) async -> String? {
        guard gate.isUnlocked else { return nil }
        let key = "\(id)/\(kind)"
        if let held = texts[key] { return held }
        let fetched: String?
        if kind == "summary" { fetched = await run { try await self.client.meetingSummary(id: id) } } else {
            fetched = await run { try await self.client.meetingTranscript(id: id) }
        }
        guard gate.isUnlocked, let fetched else { return nil }
        texts[key] = fetched
        return fetched
    }

    func stopRecording() async {
        let done: Void? = await run { try await self.client.stopMeeting() }
        if done != nil { await reload() }
    }

    func regenerate(_ meeting: RemoteMeeting, summaryOnly: Bool) async {
        let done: Void? = await run { try await self.client.regenerateMeeting(id: meeting.id, summaryOnly: summaryOnly) }
        if done != nil {
            texts["\(meeting.id)/summary"] = nil
            texts["\(meeting.id)/transcript"] = nil
            notice = "Rebuilding. The new text appears when the Mac is done."
            await reload()
        }
    }

    func ask(_ meeting: RemoteMeeting) async {
        let done: Void? = await run { try await self.client.askAboutMeeting(id: meeting.id) }
        if done != nil { notice = "Sent to Ghost. The answer is in the chat on your Mac." }
    }

    func delete(_ meeting: RemoteMeeting) async {
        let done: Void? = await run { try await self.client.deleteMeeting(id: meeting.id) }
        if done != nil { await reload() }
    }
}

// MARK: Settings

/// The phone's settings: the part of the Mac's config it may change, the pet gallery and usage.
@MainActor @Observable
final class PhoneSettingsModel: SocketModel {
    private(set) var config: RemoteConfig?
    private(set) var pets: [RemotePetChoice] = []
    private(set) var usage: RemoteUsage?
    private(set) var usageDays = 7

    override func reload() async {
        if let fresh = await run({ try await self.client.settings() }) { config = fresh }
        if let list = await run({ try await self.client.pets() }) { pets = list }
        if let fresh = await run({ try await self.client.usage(days: self.usageDays) }) { usage = fresh }
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.settingsChanged, RemoteEvent.assetsChanged: await reload()
        default: break
        }
    }

    /// Sends a merge patch. A key the Mac does not allow comes back as the error text.
    func patch(_ patch: [String: Any]) async {
        if let fresh = await run({ try await self.client.patchSettings(patch) }) { config = fresh }
    }

    func select(_ pet: RemotePetChoice) async {
        let done: Void? = await run { try await self.client.selectPet(id: pet.id) }
        if done != nil { await reload() }
    }

    func setUsageDays(_ days: Int) async {
        usageDays = days
        if let fresh = await run({ try await self.client.usage(days: days) }) { usage = fresh }
    }
}
