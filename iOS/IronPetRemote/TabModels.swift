import Foundation
import IronPetKit
import Observation
import SwiftUI
import UIKit

/// Runs a reload once a burst of events under one key has settled for 300 ms. A replay of many events, or a burst of one kind, reads each
/// screen once instead of once per event, which is how the Mac's rate limit gets hit.
@MainActor
final class EventDebouncer {
    private var pending: [String: Task<Void, Never>] = [:]

    func run(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        pending[key]?.cancel()
        pending[key] = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    func cancelAll() {
        for task in pending.values { task.cancel() }
        pending = [:]
    }
}

/// What every tab model does with the event socket: read it until `stop()`, reload when it opens or resyncs, and drop the token on a 401.
/// Every request goes through `read` or `run`, which report to `network`, so no screen keeps an error of its own or retries by itself.
@MainActor @Observable
class SocketModel {
    /// Event-driven reloads go through this, so a burst reads each screen once. Cancelled on `stop()`.
    @ObservationIgnored let debouncer = EventDebouncer()
    @ObservationIgnored let client: IronPetClient
    @ObservationIgnored let events: any EventSignalSource
    @ObservationIgnored let onUnauthorized: () -> Void
    @ObservationIgnored let network: NetworkHealth
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var reconnectListener: Task<Void, Never>?
    @ObservationIgnored private var readsWorked = 0
    @ObservationIgnored private var readsFailed = 0
    /// A line for a problem that is not the network, such as a photo the phone could not read. A failed request never sets it.
    var errorMessage: String?
    /// The error of the last request that failed, for a subclass that treats one status in its own way.
    @ObservationIgnored private(set) var lastError: Error?
    /// True once a read worked, so the screen has data to keep showing while the connection is down.
    var loaded = false
    /// The first load finished and nothing came back. The screen shows the full-page error with Retry, and only until a read works.
    private(set) var loadFailed = false
    /// A read in the last refresh failed, so an empty list may only mean the read did not work. "Nothing here" waits for a clean refresh.
    private(set) var lastRefreshFailed = false

    init(client: IronPetClient, events: any EventSignalSource, network: NetworkHealth? = nil, onUnauthorized: @escaping () -> Void) {
        self.client = client
        self.events = events
        self.network = network ?? NetworkHealth()
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
        let reconnects = network.reconnects()
        reconnectListener = Task { [weak self] in
            for await _ in reconnects {
                guard let self else { return }
                await self.refresh()
            }
        }
        Task { await refresh() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        debouncer.cancelAll()
        reconnectListener?.cancel()
        reconnectListener = nil
    }

    func refresh() async {
        let worked = readsWorked, failed = readsFailed
        await reload()
        // A cancelled load never read the Mac, so an empty list after it is not "no meetings". The load that follows sets `loaded`.
        // This checks the calling task, so a second refresh running at the same time cannot change the answer.
        guard !Task.isCancelled else { return }
        let nothingCame = readsFailed > failed && readsWorked == worked
        lastRefreshFailed = readsFailed > failed
        if !nothingCame { loaded = true }
        loadFailed = nothingCame && !loaded
    }

    /// The full-page error: the screen has never loaded, and the last try failed.
    var showsLoadError: Bool { loadFailed && !loaded }

    func handle(_ signal: EventSignal) async {
        switch signal {
        // The socket opening is the first proof that the Mac is there, so the connection state clears before the screens read.
        case .connected, .resync:
            network.reportAnswered(announce: false)
            await refresh()
        // The Mac replayed what this phone missed, so what the screen shows is current.
        case .resumed: network.reportAnswered(announce: false)
        case .disconnected: network.reportUnreachable()
        case .unauthorized: onUnauthorized()
        case .event(let event): await handle(event)
        }
    }

    /// Subclasses reload what an event changed.
    func handle(_ event: RemoteEvent) async {}

    /// Subclasses read their resource again.
    func reload() async {}

    /// Subclasses look at a failed request, for example to notice a Mac that is too old for this app.
    func didFail(_ error: Error) {}

    /// Reads a resource through the shared retry policy. A failure is not shown here: the screen keeps what it has and the strip speaks.
    /// `retriesTimeouts: false` is for a big read: a timeout there means the Mac is slow, and a second try only queues the same work again.
    @discardableResult
    func read<T>(retriesTimeouts: Bool = true, _ call: () async throws -> T) async -> T? { await perform(retrying: true, retriesTimeouts: retriesTimeouts, call) }

    /// Runs one request that changes something on the Mac, once. A retry could send it twice.
    @discardableResult
    func run<T>(_ call: () async throws -> T) async -> T? { await perform(retrying: false, call) }

    private func perform<T>(retrying: Bool, retriesTimeouts: Bool = true, _ call: () async throws -> T) async -> T? {
        do {
            let value = retrying
                ? try await RequestRetry.perform(network.retryPolicy, sleep: network.sleep, retriesTimeouts: retriesTimeouts, call)
                : try await call()
            readsWorked += 1
            if !retrying { errorMessage = nil }
            network.reportAnswered()
            return value
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch is CancellationError {
            // The app cancelled the request. It is not a failure to show.
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            readsFailed += 1
            lastError = error
            network.report(error)
            // A change the Mac refuses comes back in the Mac's own words ("cannot be changed from the phone"). That is an answer to what
            // the person asked for, not a network state. A failed read has nothing to say, so it stays quiet.
            if !retrying, case ClientError.api(_, _, let message) = error { errorMessage = message }
            didFail(error)
        }
        return nil
    }
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

    /// A task (an older Mac still sends them) opens the Inbox, a session Agents. An alert or a meeting opens More, on `MoreDestination.destination(for:)`.
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
    case alerts, automations, meetings, memory, screen, settings, phoneAgent
    /// A memory page, by its `page_` ref. A link inside a page pushes the next one.
    case memoryPage(String)

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

    init(client: IronPetClient, events: any EventSignalSource, cache: AssetCache, network: NetworkHealth? = nil, onUnauthorized: @escaping () -> Void) {
        self.cache = cache
        super.init(client: client, events: events, network: network, onUnauthorized: onUnauthorized)
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
            debouncer.run("pet") { [weak self] in await self?.reloadPet(applyMood: false) }
        case RemoteEvent.bubbleShown, RemoteEvent.bubbleDismissed:
            debouncer.run("bubbles") { [weak self] in await self?.reloadBubbles() }
        case RemoteEvent.assetsChanged:
            debouncer.run("assets") { [weak self] in
                await self?.reloadPet(applyMood: false)
                await self?.syncAssets()
            }
        // The Mac's background (and its accent colour) are part of the pet resource, so a change in the Mac's Settings shows at once.
        case RemoteEvent.alertsChanged, RemoteEvent.agentsChanged, RemoteEvent.settingsChanged:
            debouncer.run("pet") { [weak self] in await self?.reloadPet(applyMood: false) }
        default: break
        }
    }

    private func setMood(_ next: String) {
        guard next != mood else { return }
        mood = next
        moodStarted = Date()
    }

    func reloadPet(applyMood: Bool) async {
        guard let fresh = await read({ try await self.client.pet() }) else {
            // A Mac that does not know the pet route is older than this phone app, which only an update on the Mac fixes.
            if case ClientError.api(404, _, _)? = lastError { network.raise(.macTooOld) }
            return
        }
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
        if let list = await read({ try await self.client.bubbles() }) { bubbles = list }
    }

    /// Fetches the manifest, downloads the sheet if its hash is new and decodes it. A sheet that is already loaded stays as it is.
    func syncAssets() async {
        guard let result = await read({ try await self.cache.sync(with: self.client) }) else { return }
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
        if let list = await read({ try await self.client.agents() }) { agents = list }
    }

    override func handle(_ event: RemoteEvent) async {
        if event.kind == RemoteEvent.agentsChanged { debouncer.run("agents") { [weak self] in await self?.reload() } }
    }

    func detail(_ id: String) async -> RemoteAgent? { await read { try await self.client.agent(id: id) } }

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
        if let list = await read({ try await self.client.alerts() }) { alerts = list }
    }

    override func handle(_ event: RemoteEvent) async {
        if event.kind == RemoteEvent.alertsChanged { debouncer.run("alerts") { [weak self] in await self?.reload() } }
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
        if let fresh = await read({ try await self.client.today(kind: wanted.rawValue) }), wanted == kind { today = fresh }
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.suggestionsChanged, RemoteEvent.agentsChanged, RemoteEvent.alertsChanged, "meetings.changed":
            debouncer.run("today") { [weak self] in await self?.reload() }
        default: break
        }
    }
}
