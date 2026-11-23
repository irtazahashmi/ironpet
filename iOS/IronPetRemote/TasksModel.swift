import Foundation
import IronPetKit
import Observation

/// The Tasks tab: the list as the Mac's `TaskListView` groups it, kept current by the event socket.
@MainActor @Observable
final class TasksModel {
    private(set) var tasks: [RemoteTask] = []
    private(set) var suggestions: [RemoteSuggestion] = []
    private(set) var loaded = false
    var errorMessage: String?
    /// The Mac's saved quick filters, in chip order. Empty when the Mac predates them, which hides the chips.
    private(set) var filters: [QuickFilter] = []
    /// False once the Mac answered 404 to the filter route.
    private(set) var filtersSupported = true
    /// The chosen filter's id. Nil is "All". An id the Mac no longer has counts as "All" and is cleared on the next reload.
    /// Saved on this phone, so it survives a relaunch.
    var selectedFilterID: String? {
        didSet { if selectedFilterID != oldValue { QuickFilterSelection.save(selectedFilterID, defaults) } }
    }

    @ObservationIgnored let client: IronPetClient
    @ObservationIgnored private let events: any EventSignalSource
    @ObservationIgnored private let onUnauthorized: () -> Void
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(client: IronPetClient, events: (any EventSignalSource)? = nil, defaults: UserDefaults = .standard, onUnauthorized: @escaping () -> Void) {
        self.client = client
        self.defaults = defaults
        self.selectedFilterID = QuickFilterSelection.load(defaults)
        self.events = events ?? EventConnection(client: client)
        self.onUnauthorized = onUnauthorized
    }

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

    /// Loads the list, then follows the event socket until `stop()`.
    func start() {
        guard listener == nil else { return }
        let signals = events.signals()
        listener = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                await self.handle(signal)
            }
        }
        Task { await reload() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func handle(_ signal: EventSignal) async {
        switch signal {
        case .connected, .resync: await reload()
        case .unauthorized: onUnauthorized()
        case .event(let event):
            switch event.kind {
            case RemoteEvent.tasksChanged: await reloadTasks()
            case RemoteEvent.suggestionsChanged: await reloadSuggestions()
            case RemoteEvent.settingsChanged: await reloadFilters()
            default: break
            }
        }
    }

    func reload() async {
        await reloadTasks()
        await reloadSuggestions()
        await reloadFilters()
        loaded = true
    }

    /// A 404 means the Mac is older than quick filters: no chips, and no error banner.
    func reloadFilters() async {
        do {
            filters = QuickFilter.chips(try await client.taskFilters())
            filtersSupported = true
            if let id = selectedFilterID, !filters.contains(where: { $0.id == id }) { selectedFilterID = nil }
        } catch ClientError.api(let status, _, _) where status == 404 {
            filters = []
            filtersSupported = false
            selectedFilterID = nil
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch {
            // Keep the chips that are shown; the task list has its own error banner.
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
        if let list = await run({ try await self.client.tasks() }) { tasks = list }
    }

    func reloadSuggestions() async {
        if let list = await run({ try await self.client.suggestions() }) { suggestions = list }
    }

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
            errorMessage = error.localizedDescription
        }
        return nil
    }

    // MARK: Actions

    func add(_ suggestion: RemoteSuggestion) async {
        if await run({ try await self.client.acceptSuggestion(id: suggestion.id) }) != nil { await reload() }
    }

    func skip(_ suggestion: RemoteSuggestion) async {
        if await run({ try await self.client.rejectSuggestion(id: suggestion.id) }) != nil { await reload() }
    }

    func detail(_ id: String) async -> RemoteTaskDetail? { await run { try await self.client.task(id: id) } }

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
