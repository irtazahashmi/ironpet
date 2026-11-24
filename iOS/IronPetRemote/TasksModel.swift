import Foundation
import IronPetKit
import Observation

/// The Tasks tab: the list as the Mac's `TaskListView` groups it, kept current by the event socket.
@MainActor @Observable
final class TasksModel: SocketModel {
    private(set) var tasks: [RemoteTask] = []
    private(set) var suggestions: [RemoteSuggestion] = []
    /// The Mac's saved quick filters, in chip order. Empty when the Mac predates them, which hides the chips.
    private(set) var filters: [QuickFilter] = []
    /// False once the Mac answered 404 to the filter route.
    private(set) var filtersSupported = true
    /// The chosen filter's id. Nil is "All". An id the Mac no longer has counts as "All" and is cleared on the next reload.
    /// Saved on this phone, so it survives a relaunch.
    var selectedFilterID: String? {
        didSet { if selectedFilterID != oldValue { QuickFilterSelection.save(selectedFilterID, defaults) } }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Which tasks changed on the phone and have not reached the Mac. Nothing until the task sync queue plugs in.
    @ObservationIgnored var pendingSync: any PendingSyncSource = NoPendingSync()

    init(client: IronPetClient, events: (any EventSignalSource)? = nil, defaults: UserDefaults = .standard, network: NetworkHealth? = nil,
         onUnauthorized: @escaping () -> Void) {
        self.defaults = defaults
        self.selectedFilterID = QuickFilterSelection.load(defaults)
        super.init(client: client, events: events ?? EventConnection(client: client), network: network, onUnauthorized: onUnauthorized)
    }

    /// True while the task has a change that the Mac has not confirmed.
    func isPendingSync(_ id: String) -> Bool { pendingSync.isPendingSync(taskID: id) }

    // MARK: Sections

    /// The tasks the chosen quick filter keeps. The filter reads the same fields as on the Mac, so a chip shows the same set there.
    var visibleTasks: [RemoteTask] {
        guard let node = activeFilter else { return tasks }
        let now = Date()
        return tasks.filter { node.matches($0, now: now) }
    }

    var activeFilter: QuickFilterNode? { selectedFilterID.flatMap { id in filters.first { $0.id == id }?.node } }

    private var open: [RemoteTask] { visibleTasks.filter { $0.status != .done } }
    var needsYou: [RemoteTask] { open.filter { $0.waitingOn == nil && $0.status == .needsYou } }
    var inProgress: [RemoteTask] { open.filter { $0.waitingOn == nil && $0.status == .inProgress } }
    var backlog: [RemoteTask] { open.filter { $0.waitingOn == nil && $0.status == .backlog } }
    var waiting: [RemoteTask] { open.filter { $0.waitingOn != nil } }
    var done: [RemoteTask] { visibleTasks.filter { $0.status == .done } }

    // MARK: Loading

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.tasksChanged: await reloadTasks()
        case RemoteEvent.suggestionsChanged: await reloadSuggestions()
        case RemoteEvent.settingsChanged: await reloadFilters()
        default: break
        }
    }

    override func reload() async {
        await reloadTasks()
        await reloadSuggestions()
        await reloadFilters()
    }

    /// A 404 means the Mac is older than quick filters: no chips, and no error banner.
    func reloadFilters() async {
        do {
            let list = try await RequestRetry.perform(network.retryPolicy, sleep: network.sleep) { try await self.client.taskFilters() }
            network.reportAnswered()
            filters = QuickFilter.chips(list)
            filtersSupported = true
            if let id = selectedFilterID, !filters.contains(where: { $0.id == id }) { selectedFilterID = nil }
        } catch ClientError.api(let status, _, _) where status == 404 {
            network.reportAnswered()
            filters = []
            filtersSupported = false
            selectedFilterID = nil
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch is CancellationError {
        } catch {
            // Keep the chips that are shown. The strip reports the connection.
            network.report(error)
        }
    }

    /// Removes a saved filter on the Mac. Adding and editing go through the chat, so this is the only change made here.
    func removeFilter(_ filter: QuickFilter) async -> Bool {
        let removed = await run { try await self.client.deleteTaskFilter(id: filter.id) } != nil
        if removed {
            if selectedFilterID == filter.id { selectedFilterID = nil }
            await reloadFilters()
        }
        return removed
    }

    func reloadTasks() async {
        if let list = await read({ try await self.client.tasks() }) { tasks = list }
    }

    func reloadSuggestions() async {
        if let list = await read({ try await self.client.suggestions() }) { suggestions = list }
    }

    // MARK: Actions

    func add(_ suggestion: RemoteSuggestion) async {
        if await run({ try await self.client.acceptSuggestion(id: suggestion.id) }) != nil { await reload() }
    }

    func skip(_ suggestion: RemoteSuggestion) async {
        if await run({ try await self.client.rejectSuggestion(id: suggestion.id) }) != nil { await reload() }
    }

    func detail(_ id: String) async -> RemoteTaskDetail? { await read { try await self.client.task(id: id) } }

    func close(_ id: String, note: String) async -> Bool {
        let done = await run { try await self.client.closeTask(id: id, note: note) } != nil
        if done { await reloadTasks() }
        return done
    }

    func addNote(_ id: String, note: String) async -> Bool {
        let done = await run { try await self.client.addNote(id: id, note: note) } != nil
        if done { await reloadTasks() }
        return done
    }

    func setStatus(_ id: String, status: TaskStatus, note: String) async -> Bool {
        let done = await run { try await self.client.setStatus(id: id, status: status, note: note) } != nil
        if done { await reloadTasks() }
        return done
    }
}
