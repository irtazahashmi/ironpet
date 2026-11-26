import Foundation
import IronPetKit
import Observation

/// The Tasks tab: the list as the Mac's `TaskListView` groups it, kept current by the event socket.
@MainActor @Observable
final class TasksModel: SocketModel {
    /// What the list shows: the Mac's tasks with the changes still waiting to sync applied on top.
    private(set) var tasks: [RemoteTask] = []
    private(set) var suggestions: [RemoteSuggestion] = []
    /// The Mac's agents, to show a task's assignee by name. Empty on a Mac that has no agent list.
    private(set) var agents: [RemoteAgentRecord] = []
    /// The Mac's saved quick filters, in chip order. Empty when the Mac predates them, which hides the chips.
    private(set) var filters: [QuickFilter] = []
    /// False once the Mac answered 404 to the filter route.
    private(set) var filtersSupported = true
    /// The chosen filter's id. Nil is "All". An id the Mac no longer has counts as "All" and is cleared on the next reload.
    /// Saved on this phone, so it survives a relaunch.
    var selectedFilterID: String? {
        didSet { if selectedFilterID != oldValue { QuickFilterSelection.save(selectedFilterID, defaults) } }
    }

    /// The changes made on the phone that the Mac has not confirmed, oldest first. They are saved, so a relaunch keeps them.
    private(set) var pendingOps: [TaskOp] = []

    @ObservationIgnored private let syncStore: (any TaskSyncStoring)?
    @ObservationIgnored private var serverTasks: [RemoteTask] = []
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private let defaults: UserDefaults
    /// Done tasks are asked for only while the Done section is open, so a collapsed list does not carry them.
    private(set) var showsDone = false

    init(client: IronPetClient, events: (any EventSignalSource)? = nil, defaults: UserDefaults = .standard, store: (any TaskSyncStoring)? = nil,
         network: NetworkHealth? = nil, onUnauthorized: @escaping () -> Void) {
        self.syncStore = store
        self.defaults = defaults
        self.selectedFilterID = QuickFilterSelection.load(defaults)
        super.init(client: client, events: events ?? EventConnection(client: client), network: network, onUnauthorized: onUnauthorized)
        // The last list the Mac sent and the changes that never reached it show at once, before the first request.
        if let snapshot = store?.loadSnapshot() {
            serverTasks = snapshot.tasks
            filters = snapshot.filters
            filtersSupported = snapshot.filtersSupported
            loaded = true
        }
        pendingOps = store?.loadOps() ?? []
        rebuild()
    }

    // MARK: Pending sync

    /// True while a change to this task waits for the Mac. A created task has a local id until the Mac answers.
    func isPendingSync(_ id: String) -> Bool {
        #if DEBUG
        if debugAllPending { return true }
        #endif
        return pendingOps.contains { $0.taskID == id }
    }

    #if DEBUG
    /// UI tests mark every task as waiting to sync, to take a screenshot of the mark without queueing real changes.
    @ObservationIgnored var debugAllPending = false
    #endif

    /// The ids of the tasks with a change waiting for the Mac.
    var pendingSyncIDs: Set<String> { Set(pendingOps.map(\.taskID)) }

    /// The shown list: the Mac's tasks, then each waiting change in the order it was made.
    private func rebuild() {
        var list = serverTasks
        for op in pendingOps {
            if op.kind == .create {
                if !list.contains(where: { $0.id == op.taskID }) { list.append(op.created()) }
            } else if let index = list.firstIndex(where: { $0.id == op.taskID }) {
                list[index] = op.applied(to: list[index], now: op.queuedAt)
            }
        }
        tasks = list
    }

    private func persistOps() { syncStore?.saveOps(pendingOps) }

    private func persistSnapshot() {
        syncStore?.saveSnapshot(TaskSnapshot(tasks: serverTasks, filters: filters, filtersSupported: filtersSupported))
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

    /// The Mac is reachable again: send what waited for it first, so the reload shows the result.
    override func reload() async {
        await flush()
        await reloadTasks()
        await reloadSuggestions()
        await reloadFilters()
        await reloadAgents()
    }

    /// A Mac from before agent records answers 404. The phone then shows an assignee's id, and "You" for the rest.
    func reloadAgents() async {
        if let list = try? await client.agentRecords() { agents = list }
    }

    /// "You" or the assigned agent's name.
    func assigneeName(_ task: RemoteTask) -> String { task.assigneeName(in: agents) }

    override func handle(_ signal: EventSignal) async {
        if case .resumed = signal { await flush() }
        await super.handle(signal)
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.tasksChanged: debouncer.run("tasks") { [weak self] in await self?.reloadTasks() }
        case RemoteEvent.suggestionsChanged: debouncer.run("suggestions") { [weak self] in await self?.reloadSuggestions() }
        case RemoteEvent.settingsChanged: debouncer.run("filters") { [weak self] in await self?.reloadFilters() }
        default: break
        }
    }

    /// A 404 means the Mac is older than quick filters: no chips, and no error banner.
    func reloadFilters() async {
        do {
            let list = try await RequestRetry.perform(network.retryPolicy, sleep: network.sleep) { try await self.client.taskFilters() }
            network.reportAnswered()
            filters = QuickFilter.chips(list)
            filtersSupported = true
            persistSnapshot()
            if let id = selectedFilterID, !filters.contains(where: { $0.id == id }) { selectedFilterID = nil }
        } catch ClientError.api(let status, _, _) where status == 404 {
            network.reportAnswered()
            filters = []
            filtersSupported = false
            selectedFilterID = nil
            persistSnapshot()
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
        if let list = await read({ try await self.client.tasks(includeDone: self.showsDone) }) {
            serverTasks = list
            rebuild()
            persistSnapshot()
        }
    }

    /// The Done section opened or closed. Opening it asks the Mac for the done tasks; closing it drops them from the list.
    func setShowsDone(_ shown: Bool) async {
        guard showsDone != shown else { return }
        showsDone = shown
        await reloadTasks()
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

    func detail(_ id: String) async -> RemoteTaskDetail? {
        // A task created offline has no page on the Mac yet.
        if TaskOp.isLocal(id) { return nil }
        return await read { try await self.client.task(id: id) }
    }

    /// Each change applies on the phone at once, waits in `pendingOps` and goes to the Mac in order. True when the Mac took it or it is
    /// still waiting for a connection. False when the Mac refused it, which also puts its reason in `errorMessage` and undoes the change.
    func close(_ id: String, note: String) async -> Bool {
        guard let task = tasks.first(where: { $0.id == id }) else { return false }
        var op = TaskOp.make(.close, on: task)
        op.note = note
        return await submit(op)
    }

    func setStatus(_ id: String, status: TaskStatus, note: String) async -> Bool {
        guard let task = tasks.first(where: { $0.id == id }) else { return false }
        var op = TaskOp.make(.status, on: task)
        op.status = status
        op.note = note
        return await submit(op)
    }

    /// Changes the title, the notes or both. A field that is the same as it is now is not sent.
    func edit(_ id: String, title: String, notes: String) async -> Bool {
        guard let task = tasks.first(where: { $0.id == id }) else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        var op = TaskOp.make(.edit, on: task)
        op.title = title == task.title ? nil : title
        op.notes = notes == task.notes ? nil : notes
        if op.isEmpty { return true }
        return await submit(op)
    }

    func create(title: String, notes: String = "", status: TaskStatus = .backlog) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let id = UUID()
        let op = TaskOp(id: id, kind: .create, taskID: TaskOp.localID(id), queuedAt: Date(), title: title, notes: notes, status: status)
        return await submit(op)
    }

    func addNote(_ id: String, note: String) async -> Bool {
        let done = await run { try await self.client.addNote(id: id, note: note) } != nil
        if done { await reloadTasks() }
        return done
    }

    // MARK: Sync

    private func submit(_ op: TaskOp) async -> Bool {
        pendingOps.append(op)
        rebuild()
        persistOps()
        let refused = await flush()
        return !refused.contains(op.id)
    }

    private enum Outcome {
        case applied(RemoteTask?)
        case dropped(String?)
        case refused(String)
        case unreachable
        case unauthorized
    }

    /// Sends the waiting changes to the Mac, oldest first, and stops at the first one the Mac cannot be reached for. Returns the ids of
    /// the changes the Mac refused. A second call while one runs returns at once: the running one picks the new change up.
    @discardableResult
    func flush() async -> Set<UUID> {
        guard !flushing else { return [] }
        flushing = true
        defer { flushing = false }
        var refused = Set<UUID>()
        var message: String?
        var sentAny = false
        loop: while let op = pendingOps.first {
            switch await send(op) {
            case .applied(let task):
                sentAny = true
                finish(op, answer: task)
            case .dropped(let reason):
                sentAny = true
                finish(op, answer: nil)
                message = reason ?? message
            case .refused(let reason):
                sentAny = true
                refused.insert(op.id)
                finish(op, answer: nil)
                message = reason
            case .unreachable:
                break loop
            case .unauthorized:
                onUnauthorized()
                break loop
            }
        }
        if sentAny { await reloadTasks() }
        // The reload clears the banner on success, so the refusal is set after it.
        if let message { errorMessage = message }
        return refused
    }

    /// Takes the op off the queue. A created task's local id becomes the Mac's id in the changes behind it. A refused create takes the
    /// changes made to that task with it.
    private func finish(_ op: TaskOp, answer: RemoteTask?) {
        pendingOps.removeAll { $0.id == op.id }
        // The Mac stamped the task with a new `updated` time. The changes behind this one were based on the same copy, so they are now
        // based on that stamp, and do not come back with a 409 for a change the phone made itself.
        if op.kind != .create, let answer {
            for index in pendingOps.indices where pendingOps[index].taskID == op.taskID && pendingOps[index].baseUpdated == op.baseUpdated {
                pendingOps[index].baseUpdated = answer.updated
            }
        }
        if op.kind == .create {
            if let answer {
                for index in pendingOps.indices where pendingOps[index].taskID == op.taskID {
                    pendingOps[index].taskID = answer.id
                    pendingOps[index].baseUpdated = answer.updated
                }
            } else {
                pendingOps.removeAll { $0.taskID == op.taskID }
            }
        }
        rebuild()
        persistOps()
    }

    private func send(_ first: TaskOp) async -> Outcome {
        var op = first
        for _ in 0..<3 {
            if op.kind != .create, TaskOp.isLocal(op.taskID) { return .dropped(nil) }
            do {
                let task = try await perform(op)
                network.reportAnswered()
                return .applied(task)
            } catch ClientError.api(let status, _, _) where status == 409 && op.kind != .create {
                // The task changed on the Mac after the phone read it. The Mac's value wins for each field it changed.
                do {
                    let mac = try await client.task(id: op.taskID).task
                    op = op.droppingFieldsChanged(onTheMac: mac)
                    if op.isEmpty { return .dropped(nil) }
                    if let index = pendingOps.firstIndex(where: { $0.id == op.id }) { pendingOps[index] = op; persistOps() }
                } catch {
                    return outcome(for: error, op)
                }
            } catch {
                return outcome(for: error, op)
            }
        }
        return .refused("The task keeps changing on the Mac, so your change was not sent.")
    }

    private func outcome(for error: Error, _ op: TaskOp) -> Outcome {
        if !(error is CancellationError), error as? ClientError != .unauthorized { network.report(error) }
        switch error {
        case ClientError.unauthorized: return .unauthorized
        case is CancellationError: return .unreachable
        case ClientError.api(let status, _, _) where status == 404 && op.kind != .create:
            return .dropped("A task you changed is no longer on the Mac, so the change was not sent.")
        default:
            return ChatModel.isUnreachable(error) ? .unreachable : .refused(error.localizedDescription)
        }
    }

    private func perform(_ op: TaskOp) async throws -> RemoteTask {
        let clientID = op.id.uuidString
        switch op.kind {
        case .create:
            return try await client.createTask(title: op.title ?? "", notes: op.notes ?? "", status: op.status ?? .backlog, clientID: clientID)
        case .status:
            return try await client.setStatus(id: op.taskID, status: op.status ?? .backlog, note: op.note, clientID: clientID, baseUpdated: op.baseUpdated)
        case .edit:
            return try await client.editTask(id: op.taskID, title: op.title, notes: op.notes, clientID: clientID, baseUpdated: op.baseUpdated)
        case .close:
            return try await client.closeTask(id: op.taskID, note: op.note, clientID: clientID, baseUpdated: op.baseUpdated)
        }
    }
}
