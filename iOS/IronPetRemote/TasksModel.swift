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

    @ObservationIgnored let client: IronPetClient
    @ObservationIgnored private let events: EventConnection
    @ObservationIgnored private let onUnauthorized: () -> Void
    @ObservationIgnored private var listener: Task<Void, Never>?

    init(client: IronPetClient, events: EventConnection? = nil, onUnauthorized: @escaping () -> Void) {
        self.client = client
        self.events = events ?? EventConnection(client: client)
        self.onUnauthorized = onUnauthorized
    }

    // MARK: Sections

    private var open: [RemoteTask] { tasks.filter { $0.status != .done } }
    var needsYou: [RemoteTask] { open.filter { $0.waitingOn == nil && $0.status == .needsYou } }
    var inProgress: [RemoteTask] { open.filter { $0.waitingOn == nil && $0.status == .inProgress } }
    var backlog: [RemoteTask] { open.filter { $0.waitingOn == nil && $0.status == .backlog } }
    var waiting: [RemoteTask] { open.filter { $0.waitingOn != nil } }
    var done: [RemoteTask] { tasks.filter { $0.status == .done } }

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
            default: break
            }
        }
    }

    func reload() async {
        await reloadTasks()
        await reloadSuggestions()
        loaded = true
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
