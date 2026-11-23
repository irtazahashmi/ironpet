import Foundation
import IronPetKit
import Observation
import SwiftUI
import UIKit

/// What every tab model does with the event socket: read it until `stop()`, reload when it opens or resyncs, and drop the token on a 401.
@MainActor @Observable
class SocketModel {
    @ObservationIgnored let client: IronPetClient
    @ObservationIgnored let events: any EventSignalSource
    @ObservationIgnored let onUnauthorized: () -> Void
    @ObservationIgnored private var listener: Task<Void, Never>?
    var errorMessage: String?
    private(set) var loaded = false

    init(client: IronPetClient, events: any EventSignalSource, onUnauthorized: @escaping () -> Void) {
        self.client = client
        self.events = events
        self.onUnauthorized = onUnauthorized
    }

    /// Loads once, then follows the socket until `stop()`.
    func start() {
        guard listener == nil else { return }
        let signals = events.signals()
        listener = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                await self.handle(signal)
            }
        }
        Task { await refresh() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func refresh() async {
        await reload()
        loaded = true
    }

    func handle(_ signal: EventSignal) async {
        switch signal {
        case .connected, .resync: await refresh()
        case .unauthorized: onUnauthorized()
        case .event(let event): await handle(event)
        }
    }

    /// Subclasses reload what an event changed.
    func handle(_ event: RemoteEvent) async {}

    /// Subclasses read their resource again.
    func reload() async {}

    /// Runs one request. A 401 drops the token; any other failure becomes the visible error.
    @discardableResult
    func run<T>(_ call: () async throws -> T) async -> T? {
        do {
            let value = try await call()
            errorMessage = nil
            return value
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch is CancellationError {
        } catch {
            errorMessage = message(for: error)
        }
        return nil
    }

    /// The text `run` shows for a failed request. A subclass that must not show URLSession's wording replaces it.
    func message(for error: Error) -> String { error.localizedDescription }
}

/// The tabs of the app. Alerts, Automations, Meetings, Screen and Settings sit behind More.
enum AppTab: Hashable {
    case pet, chat, tasks, agents, more

    /// The tab's icon, from the table the Mac's sidebar reads too.
    var symbol: String {
        switch self {
        case .pet: return SharedSymbols.pet
        case .chat: return SharedSymbols.chat
        case .tasks: return SharedSymbols.tasks
        case .agents: return SharedSymbols.agents
        case .more: return SharedSymbols.more
        }
    }

    /// A task opens Tasks, a session Agents. An alert or a meeting opens More, on `MoreDestination.destination(for:)`.
    static func tab(for target: TodayTarget) -> AppTab? {
        switch target.type {
        case .task: return .tasks
        case .session: return .agents
        case .alert, .meeting: return .more
        }
    }
}

/// The screens behind the More tab.
enum MoreDestination: Hashable {
    case alerts, automations, meetings, screen, settings

    static func destination(for target: TodayTarget) -> MoreDestination? {
        switch target.type {
        case .alert: return .alerts
        case .meeting: return .meetings
        case .task, .session: return nil
        }
    }
}

// MARK: Pet

/// The Pet tab: the Mac's pet with its mood, badge, bubbles and tricks, drawn from the sheet in the asset cache.
@MainActor @Observable
final class PetModel: SocketModel {
    private(set) var pet: RemotePet?
    private(set) var bubbles: [RemoteBubble] = []
    private(set) var atlas: Atlas?
    /// The mood the sprite plays. It follows `pet.mood` events and each full read.
    private(set) var mood = "idle"
    /// Set when a trick was sent, for a moment of feedback.
    var lastTrick: String?
    /// When the current mood started, so the sprite plays its row from the first frame.
    private(set) var moodStarted = Date()
    /// The picture the Mac uses as its chat background, when `background` is `custom`.
    private(set) var backgroundImage: UIImage?
    @ObservationIgnored let cache: AssetCache
    @ObservationIgnored private var spriteHash: String?
    @ObservationIgnored private var backgroundHash: String?

    init(client: IronPetClient, events: any EventSignalSource, cache: AssetCache, onUnauthorized: @escaping () -> Void) {
        self.cache = cache
        super.init(client: client, events: events, onUnauthorized: onUnauthorized)
    }

    /// The row the sprite plays now. A sheet without the row (a Codex sheet has no drinking or stretching) plays waving.
    var row: AtlasRow { PetAnimation.row(forMood: mood, in: atlas) }
    var followUp: AtlasRow? { PetAnimation.followUp(forMood: mood) }
    var badge: Int { pet?.badge ?? 0 }
    /// The Mac's chat background: a built-in id, `default` or `custom`.
    var backgroundID: String { pet?.background ?? ChatBackgrounds.defaultID }
    /// The Mac's accent colour for links and controls, or nil to keep the system blue.
    var accent: Color? {
        guard let pair = AccentColour.pair(of: pet) else { return nil }
        func ui(_ c: AccentColour) -> UIColor { UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1) }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(pair.dark) : ui(pair.light) })
    }

    override func reload() async {
        await reloadPet(applyMood: true)
        await reloadBubbles()
        await syncAssets()
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.petMood:
            if let id = event.id { setMood(id) }
            await reloadPet(applyMood: false)
        case RemoteEvent.bubbleShown, RemoteEvent.bubbleDismissed: await reloadBubbles()
        case RemoteEvent.assetsChanged:
            await reloadPet(applyMood: false)
            await syncAssets()
        // The Mac's background (and its accent colour) are part of the pet resource, so a change in the Mac's Settings shows at once.
        case RemoteEvent.alertsChanged, RemoteEvent.agentsChanged, RemoteEvent.settingsChanged: await reloadPet(applyMood: false)
        default: break
        }
    }

    private func setMood(_ next: String) {
        guard next != mood else { return }
        mood = next
        moodStarted = Date()
    }

    func reloadPet(applyMood: Bool) async {
        guard let fresh = await run({ try await self.client.pet() }) else { return }
        pet = fresh
        if applyMood { setMood(fresh.mood) }
        publishPresence()
    }

    /// Keeps the Home Screen widget and Live Activity in sync with the Mac's pet.
    func publishPresence() {
        guard let pet else { return }
        let snapshot = PetSnapshot(name: pet.name, mood: mood, badge: pet.badge)
        PetSnapshotStore.save(snapshot)
        PetPresence.update(snapshot)
    }

    func reloadBubbles() async {
        if let list = await run({ try await self.client.bubbles() }) { bubbles = list }
    }

    /// Fetches the manifest, downloads the sheet if its hash is new and decodes it. A sheet that is already loaded stays as it is.
    func syncAssets() async {
        guard let result = await run({ try await self.cache.sync(with: self.client) }) else { return }
        syncBackground(result.current["chat.background"])
        guard let hash = result.current["pet.sprite"], hash != spriteHash else { return }
        if let data = cache.data(forHash: hash), let loaded = Atlas.load(data: data) {
            atlas = loaded
            spriteHash = hash
        }
    }

    /// Decodes the Mac's custom background when its hash changes, at most 2400 px on the long side like the Mac does.
    private func syncBackground(_ hash: String?) {
        guard hash != backgroundHash else { return }
        backgroundHash = hash
        backgroundImage = hash.flatMap { cache.data(forHash: $0) }.flatMap { PastedImage.thumbnail(from: $0, longSide: 2400) }
    }

    func perform(trick: String) async {
        if await run({ try await self.client.perform(trick: trick) }) != nil { lastTrick = trick }
    }

    func press(_ bubble: RemoteBubble, _ action: RemoteBubbleAction) async {
        if await run({ try await self.client.press(bubble: bubble.id, action: action.id) }) != nil { await reloadBubbles() }
    }
}

// MARK: Agents

@MainActor @Observable
final class AgentsModel: SocketModel {
    private(set) var agents: [RemoteAgent] = []
    /// A session id to open once the tab shows, set when a Today item points at it.
    var pendingDetail: String?
    /// The answer to the last Ask Ghost, shown once.
    var notice: String?

    var needsInput: [RemoteAgent] { agents.filter { $0.status == .needsInput } }
    var running: [RemoteAgent] { agents.filter { $0.status == .running } }
    var finished: [RemoteAgent] { agents.filter { $0.status == .done || $0.status == .failed } }

    override func reload() async {
        if let list = await run({ try await self.client.agents() }) { agents = list }
    }

    override func handle(_ event: RemoteEvent) async {
        if event.kind == RemoteEvent.agentsChanged { await reload() }
    }

    func detail(_ id: String) async -> RemoteAgent? { await run { try await self.client.agent(id: id) } }

    func acknowledge(_ agent: RemoteAgent) async {
        if await run({ try await self.client.acknowledgeAgent(id: agent.id) }) != nil { await reload() }
    }

    func ask(_ agent: RemoteAgent) async {
        if await run({ try await self.client.askAboutAgent(id: agent.id) }) != nil { notice = "Sent to Ghost. The answer is in the chat on your Mac." }
    }
}

// MARK: Alerts

@MainActor @Observable
final class AlertsModel: SocketModel {
    private(set) var alerts: [RemoteAlert] = []
    var notice: String?

    override func reload() async {
        if let list = await run({ try await self.client.alerts() }) { alerts = list }
    }

    override func handle(_ event: RemoteEvent) async {
        if event.kind == RemoteEvent.alertsChanged { await reload() }
    }

    func dismiss(_ alert: RemoteAlert) async {
        if await run({ try await self.client.dismissAlert(id: alert.id) }) != nil { await reload() }
    }

    func dismissAll() async {
        if await run({ try await self.client.dismissAllAlerts() }) != nil { await reload() }
    }

    func ask(_ alert: RemoteAlert) async {
        if await run({ try await self.client.askAboutAlert(id: alert.id) }) != nil { notice = "Sent to Ghost. The answer is in the chat on your Mac." }
    }
}

// MARK: Today

/// The brief and the recap, read again when anything they list changes.
@MainActor @Observable
final class TodayModel: SocketModel {
    enum Kind: String, CaseIterable { case brief, recap }

    var kind: Kind = .brief {
        didSet { if kind != oldValue { Task { await reload() } } }
    }
    private(set) var today: RemoteToday?

    override func reload() async {
        let wanted = kind
        if let fresh = await run({ try await self.client.today(kind: wanted.rawValue) }), wanted == kind { today = fresh }
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.tasksChanged, RemoteEvent.agentsChanged, RemoteEvent.alertsChanged, "meetings.changed": await reload()
        default: break
        }
    }
}
