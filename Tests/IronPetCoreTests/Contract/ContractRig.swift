import Foundation
import XCTest
import IronPetKit
@testable import IronPetCore

/// An `IronPetAPI` over in-memory stores and unsupported adapters, with a dispatcher on top. Every contract test builds one,
/// so the golden files run against the same code a client reaches.
@MainActor
final class ContractRig {
    /// Fixed so a golden file never holds a wall-clock time.
    static let epoch = Date(timeIntervalSince1970: 1_794_000_000)

    let api: IronPetAPI
    let dispatcher: RPCDispatcher
    let directory: URL
    /// Values the golden file captured from earlier responses, by name.
    var variables: [String: String] = [:]

    /// `seed` names the state a fixture starts from: `alerts`, `agents`, `memory`, `asks`.
    init(seed: [String] = []) throws {
        TestMemory.isolate()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = { ContractRig.epoch }
        let tasks = TaskStore(database: Self.memoryDatabase(), now: now, keepDoneDays: { 30 })
        let paths = AutomationPaths(file: directory.appendingPathComponent("automations.json"), directory: directory.appendingPathComponent("automations"))
        let store = AutomationStore(paths: paths, defaults: { [] }, watch: false)
        let engine = AutomationEngine(env: AutomationEngine.Environment(now: now, calendar: Self.calendar))
        let service = AutomationService(store: store, engine: engine)
        service.runShell = { _, _ in CommandResult(code: 0, stdout: "ok") }
        let chat = ChatSession(restore: false, speech: UnsupportedSpeechOutput())
        let signals = SignalStore()
        let sessions = SessionStore()
        api = IronPetAPI(stores: .init(
            tasks: tasks, automations: service, signals: signals, bubbles: BubbleStore(),
            notifications: NotificationStore(database: Self.memoryDatabase(), now: now), sessions: sessions, chat: chat,
            meeting: UnsupportedMeetingRecorder(), meetingLibrary: MeetingLibrary(root: directory.appendingPathComponent("meetings")),
            config: ConfigStore(memory: Config()), speech: chat.speech,
            files: FolderFileIntake(directory: directory.appendingPathComponent("attachments"))))
        api.today.now = now
        api.today.calendar = Self.calendar
        dispatcher = RPCDispatcher(api: api)

        if seed.contains("alerts") {
            signals.add(Signal(id: "alert-ci", title: "CI failed", subtitle: "main", url: nil, date: Self.epoch, label: "CI",
                               symbol: "xmark.circle", mood: .failed, ask: "Why did CI fail?"), notify: false)
        }
        if seed.contains("agents") {
            sessions.loadPreview([AgentSession(id: "session-1", source: .claude, status: .needsInput, prompt: "Fix the build",
                                               updatedAt: Self.epoch, turnStartedAt: Self.epoch)])
        }
        if seed.contains("asks") {
            api.alerts.askHandler = { _ in }
            api.agents.askHandler = { _ in }
        }
        if seed.contains("memory") {
            let memory = MemoryMCP.Services(store: FileMemoryStore(directory: directory.appendingPathComponent("memory")), index: nil)
            api.attach(memory: { memory })
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func memoryDatabase() -> Database {
        Database.open(path: nil, migrations: AppMigrations.all).database
    }

    // MARK: Running a request

    /// Sends one request line through the stdio path and returns the decoded response, normalised for comparison.
    func send(_ request: RemoteJSON, captures: [String: String] = [:]) async throws -> RemoteJSON {
        let line = try JSONEncoder().encode(substitute(request))
        let raw = await dispatcher.handle(line: line)
        let response = try JSONDecoder().decode(RemoteJSON.self, from: raw)
        for (name, path) in captures {
            if case .string(let value)? = Self.value(at: path, in: response) { variables[name] = value }
        }
        return normalize(response)
    }

    /// Replaces `"$name"` with what an earlier response captured.
    private func substitute(_ value: RemoteJSON) -> RemoteJSON {
        switch value {
        case .string(let text) where text.hasPrefix("$") && variables[String(text.dropFirst())] != nil:
            return .string(variables[String(text.dropFirst())]!)
        case .array(let items): return .array(items.map(substitute))
        case .object(let fields): return .object(fields.mapValues(substitute))
        default: return value
        }
    }

    /// Hides what changes between runs: captured ids become `$name`, other UUIDs `<uuid>`, ISO 8601 times `<date>`, and the
    /// rig's temp folder `<tmp>`.
    func normalize(_ value: RemoteJSON) -> RemoteJSON {
        switch value {
        case .string(let text):
            for (name, captured) in variables where text == captured { return .string("$" + name) }
            if text.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil {
                return .string("<uuid>")
            }
            if text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil {
                return .string("<date>")
            }
            return .string(text.replacingOccurrences(of: directory.resolvingSymlinksInPath().path, with: "<tmp>")
                .replacingOccurrences(of: directory.path, with: "<tmp>"))
        case .array(let items): return .array(items.map(normalize))
        case .object(let fields): return .object(fields.mapValues(normalize))
        default: return value
        }
    }

    /// `result.id` or `result[0].id`: a dotted path into a response.
    static func value(at path: String, in value: RemoteJSON) -> RemoteJSON? {
        var current: RemoteJSON? = value
        for part in path.split(separator: ".") {
            var name = String(part)
            var indexes: [Int] = []
            while name.hasSuffix("]"), let open = name.lastIndex(of: "["), let index = Int(name[name.index(after: open)..<name.index(before: name.endIndex)]) {
                indexes.insert(index, at: 0)
                name = String(name[..<open])
            }
            if !name.isEmpty {
                guard case .object(let fields)? = current else { return nil }
                current = fields[name]
            }
            for index in indexes {
                guard case .array(let items)? = current, items.indices.contains(index) else { return nil }
                current = items[index]
            }
        }
        return current
    }
}
