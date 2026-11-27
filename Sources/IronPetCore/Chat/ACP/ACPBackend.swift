import Foundation

package struct ChatModel: Identifiable, Hashable {
    package init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    package let id: String
    package let name: String

    /// Menu group: "Claude Opus", "Claude Sonnet", "GPT-5.6", "Grok", …
    package var family: String {
        let words = name.split(separator: " ")
        guard let first = words.first else { return "Other" }
        if first == "Claude", words.count > 1 { return "Claude \(words[1])" }
        if first == "Auto" { return "Auto" }
        return String(first)
    }
}

/// How the user can sign in to an agent, from `authMethods` in the `initialize` result.
package struct AuthMethod: Identifiable, Hashable {
    package let id: String
    package let name: String
    package let detail: String
    /// "agent" (call `authenticate`) or "terminal" (run the agent's command with `args` in a terminal).
    package let type: String
    package let args: [String]
    package let env: [String: String]

    package init(json: JSON) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? "Sign in"
        detail = json["description"] as? String ?? ""
        type = json["type"] as? String ?? "agent"
        args = json["args"] as? [String] ?? []
        env = json["env"] as? [String: String] ?? [:]
    }
}

/// A permission mode the agent advertises in `session/new`. ironpet offers exactly these and adds none.
package struct AgentMode: Equatable, Sendable {
    package let id: String
    package let name: String
    package let detail: String?
    package init(id: String, name: String, detail: String? = nil) { self.id = id; self.name = name; self.detail = detail }
}

package enum AgentEvent {
    case session(String)
    case models(current: String?, [ChatModel])
    case commands([SlashCommand])
    case assistant(String)
    case toolStarted(id: String, summary: String)
    case toolUpdated(id: String, summary: String)
    case toolFinished(id: String, ok: Bool)
    /// A tool call made by a subagent. It belongs under the subagent's own tool row (`parent`), not in the reply.
    /// `ok` is nil while the call runs.
    case subagentTool(parent: String, id: String, summary: String, ok: Bool?)
    /// The agent needs a sign-in before it can run.
    case needsSignIn([AuthMethod])
    /// The adapter has no JS runtime to run on until the user allows the Bun download.
    case needsRuntime
    case finished(error: String?)
}

/// One answer the agent offers in `session/request_permission`: `optionId`, a label, and a kind (`allow_once`, `allow_always`,
/// `reject_once`, `reject_always`, or whatever else the agent defines).
package struct PermissionOption: Codable, Equatable, Sendable, Identifiable {
    package var id: String
    package var name: String
    package var kind: String

    package init(id: String, name: String, kind: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
    }

    package init?(json: JSON) {
        guard let id = json["optionId"] as? String else { return nil }
        self.init(id: id, name: json["name"] as? String ?? id, kind: json["kind"] as? String ?? "")
    }

    package var allows: Bool { kind.hasPrefix("allow") }
}

package struct ApprovalDecision {
    package init(allow: Bool, message: String, optionID: String? = nil) {
        self.allow = allow
        self.message = message
        self.optionID = optionID
    }

    package let allow: Bool
    package let message: String
    /// The option the user chose. Sent back as it is, so an option ironpet has no name for still works.
    package let optionID: String?

    package static func choose(_ option: PermissionOption) -> ApprovalDecision {
        ApprovalDecision(allow: option.allows, message: "Chose \(option.name) in ironpet", optionID: option.id)
    }

    package static let allow = ApprovalDecision(allow: true, message: "Approved in ironpet")
    package static func deny(_ message: String = "The user denied this in ironpet") -> ApprovalDecision {
        ApprovalDecision(allow: false, message: message)
    }
}

package struct ACPTurn {
    package init(
        prompt: String,
        preamble: String?,
        workspace: URL,
        resume: String?,
        model: String?,
        images: [URL],
        files: [URL],
        allowedTools: [String]? = nil,
        disallowedTools: [String]? = nil,
        fork: String? = nil
    ) {
        self.prompt = prompt
        self.preamble = preamble
        self.workspace = workspace
        self.resume = resume
        self.model = model
        self.images = images
        self.files = files
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.fork = fork
    }

    package let prompt: String
    /// Context for the first turn of a new session (memory notes). Not sent when a session is resumed.
    package var preamble: String?
    package let workspace: URL
    /// Session to resume with `session/load` when this backend has none yet.
    package let resume: String?
    package let model: String?
    package let images: [URL]
    package let files: [URL]
    /// Tool rules for the session, from an automation's `allowedTools` and `disallowedTools`. Only the Claude Code adapter reads them.
    package var allowedTools: [String]? = nil
    package var disallowedTools: [String]? = nil
    /// Session to start from a copy of (`session/fork`), when this backend has none yet. Falls back to a new session when the
    /// agent cannot fork; `ACPBackend.forkOutcome` says which happened.
    package var fork: String? = nil
}

/// Why an agent could not be started.
package enum ACPLaunchError: LocalizedError {
    case cliMissing(String)
    case adapterMissing(String)
    case runtimeMissing
    case timedOut(String)

    package var errorDescription: String? {
        switch self {
        case .cliMissing(let command): return "\(command) was not found. Install it, then try again."
        case .adapterMissing(let adapter): return "The \(adapter) adapter is missing from this build of ironpet."
        case .runtimeMissing: return "ironpet needs Node 22 or a downloaded Bun to run this agent."
        case .timedOut(let what): return "The agent did not answer \(what) in time."
        }
    }
}

/// Drives one agent over ACP. The process lives across turns, so a chat keeps one session and Stop only cancels the turn.
@MainActor
package final class ACPBackend {
    package let agent: ACPAgent
    package private(set) var sessionID: String?
    package private(set) var capabilities: JSON = [:]
    /// The agent's process ended and `shutdown()` did not ask for it. The chat resumes the session on its next message.
    package var onUnexpectedExit: (() -> Void)?
    package private(set) var authMethods: [AuthMethod] = []
    /// How this agent takes a message into a running turn, from `_meta.steering.supported` in its `initialize` response.
    package private(set) var steering = Steering.none
    package var canSteer: Bool { steering != .none && client?.isClosed == false }

    /// The ways to put a message into a running turn.
    package enum Steering: Equatable {
        /// The agent did not advertise steering. Messages wait for the turn to end.
        case none
        /// A second `session/prompt` while the first runs. Claude Code's adapter pushes its text to Claude Code with no priority, so the
        /// agent reads it at its next step. `_session/steering` would use priority `now`, which aborts the step that is running.
        case concurrentPrompt
        /// The `_session/steering` request (Codex `turn/steer`, OpenCode).
        case request
    }

    /// What happened to a steered message.
    package enum SteerOutcome: Equatable {
        /// The running turn has the message.
        case delivered
        /// No turn was running, so the caller sends it as a normal turn.
        case notRunning
        case failed(String)
    }

    /// A restricted run gets only its own working folder: no memory or screenshot folders. Meeting summaries use it.
    package var restricted = false

    /// The feature this backend's turns count under in the Usage tab. Nil records nothing, which is the default for anything
    /// that is not an ironpet feature.
    package var usageFeature: UsageFeature?
    /// Where usage goes. Nil uses the app's `UsageStore.shared`.
    package var usageStore: UsageStore?

    /// MCP servers every unrestricted session gets, as ACP `mcpServers` entries. ironpet's own automation tools go here.
    package nonisolated(unsafe) static var defaultMCPServers: () -> [JSON] = { [] }

    /// Names this session to ironpet's own MCP server when it is not the user's chat (`automation:<id>`), so a memory note it saves is
    /// marked as outside text and not filed under the chat that happens to be open.
    package var mcpCaller: String?

    /// Receives transcript updates (text, tool calls) that arrive while no prompt is in flight, such as a background
    /// subagent's result after its turn ended.
    package var onBackground: ((AgentEvent) -> Void)?

    /// Called when a prompt goes out, the first moment a message can join the turn.
    package var onPromptSent: (() -> Void)?
    /// Reports the agent's current permission mode and every mode it advertises, at session start and when either changes.
    package var onModes: ((_ current: String?, _ modes: [AgentMode]) -> Void)?
    /// The mode the user picked for this agent in the chat. Applied when a session starts, and when `setMode` is called.
    package var preferredMode: String?

    /// Called when the agent asks to run something. Answer once.
    package var onPermission: ((ACPToolCall, @escaping (ApprovalDecision) -> Void) -> Void)?

    /// Called when the agent asks the user a question as a form (`elicitation/create`). Answer once.
    package var onElicitation: ((ElicitationForm, @escaping (ElicitationReply) -> Void) -> Void)?

    private var client: ACPClient?
    private var transport: ACPProcessTransport?
    private var sessionReady = false
    private var freshSession = false
    private var replaying = false
    private var promptInFlight = false
    /// Counts prompts, so the cancel watchdog only acts on the prompt it was started for.
    private var promptCount = 0
    /// Every `runTurn` call is numbered; `cancel()` stops all up to `cancelledThrough`, even one still connecting.
    private var turnCount = 0
    private var cancelledThrough = 0
    private var onEvent: ((AgentEvent) -> Void)?
    private var tools: [String: ACPToolCall] = [:]
    private var finishedTools: Set<String> = []
    private var pendingPermissions: [UUID: (Result<JSON, ACPError>) -> Void] = [:]
    private var pendingElicitations: [UUID: (Result<JSON, ACPError>) -> Void] = [:]
    private var models: [ChatModel] = []
    private var currentModel: String?
    private var modelConfigID: String?
    private var modeID: String?
    private var modes: [AgentMode] = []
    private var timedOut = false
    /// The session's cumulative cost as the agent last reported it in a `usage_update`. ACP reports cost for the whole session,
    /// so one turn's cost is the difference from where it stood when the turn began.
    private var reportedCost: (amount: Double, currency: String)?
    /// The part of `reportedCost` already stored in a usage record. A turn's cost is what came in since, which also covers a
    /// `usage_update` that arrives between turns.
    private var costAccounted: (amount: Double, currency: String)?
    /// True after `session/load` when the agent replayed no running cost. The agent's next total is the session's lifetime cost,
    /// not this turn's, so it only sets the baseline.
    private var costBaselineMissing = false
    private var modelReportedInTurn: String?
    private var modelAtTurnStart: String?

    package var processID: Int32? { transport?.processID }
    /// The model the session is using, as the agent last reported or accepted it.
    package var activeModel: String? { currentModel }

    /// Starts the agent's process and the probes. `AppDelegate`'s owners pass the Mac one; the default starts nothing.
    package let spawner: ProcessSpawner

    package init(agent: ACPAgent, spawner: ProcessSpawner = UnsupportedProcessSpawner()) {
        self.agent = agent
        self.spawner = spawner
    }

    // MARK: Turns

    /// Runs one prompt. Reports through `onEvent` and never throws: failures arrive as `.finished(error:)`,
    /// `.needsSignIn` or `.needsRuntime`.
    package func runTurn(_ turn: ACPTurn, onEvent: @escaping (AgentEvent) -> Void) async {
        // A cancelled turn can still be winding down. Wait for it, but never longer than the cancel watchdog allows.
        for _ in 0..<60 where promptInFlight { try? await Task.sleep(nanoseconds: 100_000_000) }
        self.onEvent = onEvent
        turnCount += 1
        let number = turnCount
        var started: Date?
        do {
            try await connect(turn.workspace)
            try await ensureSession(turn)
            await applyModel(turn.model)
            let blocks = promptBlocks(turn)
            guard let client, let sessionID else { throw ACPError(code: -1, message: "The agent stopped") }
            // Stopped while connecting or opening the session: the prompt never goes out.
            guard number > cancelledThrough else { return }
            promptInFlight = true
            promptCount += 1
            defer { promptInFlight = false }
            onPromptSent?()
            started = Date()
            modelAtTurnStart = currentModel
            modelReportedInTurn = nil
            let result = try await client.request("session/prompt", ["sessionId": sessionID, "prompt": blocks])
            recordUsage(result, started: started ?? Date())
            emit(.finished(error: result["stopReason"] as? String == "refusal" ? "The agent declined this request." : nil))
        } catch ACPLaunchError.runtimeMissing {
            emit(.needsRuntime)
        } catch let error as ACPError where error.isAuthRequired {
            emit(.needsSignIn(authMethods))
        } catch {
            // A turn that failed after the prompt went out still counts, and may have cost something.
            if let started { recordUsage([:], started: started) }
            emit(.finished(error: describe(error)))
        }
    }

    /// Puts a message into the running turn, in the way the agent advertised. Never throws.
    package func steer(_ turn: ACPTurn) async -> SteerOutcome {
        guard promptInFlight, let client, !client.isClosed, let sessionID else { return .notRunning }
        let blocks = promptBlocks(turn)
        switch steering {
        case .none:
            return .notRunning
        case .concurrentPrompt:
            // The reply streams through the running turn's updates. This request ends when the adapter settles the message's own
            // turn, which is not a turn boundary for ironpet, so only a failure matters.
            Task { [weak self] in
                do { _ = try await client.request("session/prompt", ["sessionId": sessionID, "prompt": blocks]) }
                catch { ChatLog.note("steered message failed: \(self?.describe(error) ?? "\(error)")") }
            }
            return .delivered
        case .request:
            do {
                let result = try await client.request("_session/steering", [
                    "sessionId": sessionID, "prompt": blocks, "_meta": ["steering": ["idleBehavior": "promptRequired"]]])
                return result["outcome"] as? String == "injected" ? .delivered : .notRunning
            } catch {
                return .failed(describe(error))
            }
        }
    }

    /// Stores one usage record for the turn that just ended, when this backend has a feature. Only numbers the agent reported
    /// go in: the response's `usage` object, and the cost change from `usage_update` notifications. The turn's length is the one
    /// thing ironpet measures itself.
    private func recordUsage(_ result: JSON, started: Date) {
        guard let feature = usageFeature, let store = usageStore ?? UsageStore.shared else { return }
        var event = UsageEvent(at: started, feature: feature, model: modelReportedInTurn ?? modelAtTurnStart ?? currentModel ?? "unknown",
                               duration: Date().timeIntervalSince(started))
        UsageEvent.applyACPUsage(result["usage"] as? JSON, to: &event)
        if let now = reportedCost, costBaselineMissing {
            // First total of a resumed session with nothing to subtract from. Price the turn's tokens, else leave the cost out.
            costBaselineMissing = false
            costAccounted = now
            if let priced = UsagePricing.cost(for: event) {
                event.cost = priced
                event.currency = "USD"
            }
        } else if let now = reportedCost {
            let before = costAccounted?.currency == now.currency ? costAccounted?.amount ?? 0 : 0
            if now.amount != before || costAccounted?.currency != now.currency {
                // A smaller total means the agent restarted its count, so the new total is all there is to add.
                event.cost = now.amount >= before ? now.amount - before : now.amount
                event.currency = now.currency
            }
            costAccounted = now
        }
        store.record(event)
    }

    /// Stop: tells the agent to end the turn and keeps its process for the next message.
    package func cancel() {
        onEvent = nil
        cancelledThrough = turnCount
        guard let client, !client.isClosed else { return }
        let waiting = pendingPermissions
        pendingPermissions = [:]
        waiting.values.forEach { $0(.success(["outcome": ["outcome": "cancelled"]])) }
        cancelElicitations()
        // With no prompt in flight there is no turn to cancel. Claude Code's adapter answers `session/cancel` with an
        // interrupt that also stops the background subagents, so an idle chat must not send one.
        guard promptInFlight else { return }
        if let sessionID { client.notify("session/cancel", ["sessionId": sessionID]) }
        // An agent that ignores the cancel would block the chat. After five seconds, restart it on the next message.
        // A later prompt on the same process is not the one that was cancelled, so it is left alone.
        let cancelled = promptCount
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.promptInFlight, self.promptCount == cancelled else { return }
            self.shutdown()
        }
    }

    /// Answers every open form with `cancel`, which makes the agent abort the tool call that asked.
    private func cancelElicitations() {
        let waiting = pendingElicitations
        pendingElicitations = [:]
        waiting.values.forEach { $0(.success(ElicitationReply.cancel.json)) }
    }

    package func shutdown() {
        cancelElicitations()
        client?.close()
        client = nil
        transport = nil
        sessionReady = false
        // The next session starts its own cost count.
        reportedCost = nil
        costAccounted = nil
        costBaselineMissing = false
    }

    /// Starts the agent process ahead of the first turn, so that turn does not wait for it. Failures show on the turn.
    package func prepare(_ workspace: URL) async {
        try? await connect(workspace)
    }

    /// The next turn starts a new agent session on the same process.
    package func startNewSession() {
        sessionID = nil
        sessionReady = false
    }

    package func authenticate(_ method: AuthMethod) async throws {
        try await connect(nil)
        guard let client else { return }
        _ = try await client.request("authenticate", ["methodId": method.id])
    }

    // MARK: Connection

    private func emit(_ event: AgentEvent) {
        onEvent?(event)
    }

    /// A subagent's tool call becomes a `subagentTool` event under its parent's row. The main agent's calls pass through.
    private func emitTool(_ call: ACPToolCall, _ event: AgentEvent) {
        if let parent = call.parentToolUseID {
            switch event {
            case .toolStarted(let id, let summary), .toolUpdated(let id, let summary):
                emitTranscript(.subagentTool(parent: parent, id: id, summary: summary, ok: nil))
            case .toolFinished(let id, let ok):
                emitTranscript(.subagentTool(parent: parent, id: id, summary: call.summary, ok: ok))
            default: break
            }
        } else {
            emitTranscript(event)
        }
    }

    /// Text and tool updates belong to the running turn. With no prompt in flight, they come from work the agent
    /// started earlier, and the chat shows them without a turn.
    private func emitTranscript(_ event: AgentEvent) {
        if promptInFlight { onEvent?(event) } else { onBackground?(event) }
    }

    /// What ironpet tells the agent it supports. Claude Code's adapter holds `session/prompt` open while a background
    /// subagent runs, unless the client says it takes subagent traffic after the response.
    package nonisolated static func clientCapabilities(for agent: ACPAgent) -> JSON {
        guard agent.id == "claude" else { return JSON() }
        // Form elicitation turns on the adapter's AskUserQuestion tool. URL elicitation stays off.
        return ["_meta": ["jetbrains": ["air": ["version": 1, "capabilities": ["backgroundSubagents"]]]],
                "elicitation": ["form": JSON()]]
    }

    private func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if timedOut { return "The agent did not answer in time. \(text)" }
        return text
    }

    private func connect(_ workspace: URL?) async throws {
        if let client, !client.isClosed { return }
        client = nil
        sessionReady = false
        timedOut = false
        let agent = agent, spawner = spawner
        // `launch` runs `node --version`, which must not block the main actor.
        let launch = try await Task.detached { try Self.launch(for: agent, spawner: spawner) }.value
        let transport = ACPProcessTransport(executable: launch.executable, arguments: launch.arguments, environment: launch.environment,
                                            directory: workspace, spawner: spawner)
        let client = ACPClient(transport: transport)
        client.onNotification = { [weak self] method, params in self?.notification(method, params) }
        client.onRequest = { [weak self] method, params, respond in self?.agentRequest(method, params, respond) }
        client.onClose = { [weak self, weak client] _ in
            guard let self, self.client === client else { return }
            ChatLog.note("agent process \(self.agent.id) exited; transcript untouched, next message resumes the session")
            self.sessionReady = false
            self.onUnexpectedExit?()
        }
        try client.start()
        ChatLog.note("agent process \(agent.id) started")
        self.client = client
        self.transport = transport
        logCLIVersion()
        do {
            let result = try await guarded(client, seconds: 60) {
                try await client.request("initialize", ["protocolVersion": 1, "clientCapabilities": Self.clientCapabilities(for: agent),
                                                          "clientInfo": ["name": "ironpet", "title": "ironpet", "version": "0.1.0"]])
            }
            capabilities = result["agentCapabilities"] as? JSON ?? [:]
            let advertised = ((result["_meta"] as? JSON)?["steering"] as? JSON)?["supported"] as? Bool == true
            steering = advertised ? (agent.id == "claude" ? .concurrentPrompt : .request) : .none
            authMethods = (result["authMethods"] as? [JSON] ?? []).map(AuthMethod.init(json:))
        } catch {
            client.close()
            self.client = nil
            throw error
        }
    }

    /// Closes the connection if `body` runs too long, which fails its pending request with a clear message.
    private func guarded<T>(_ client: ACPClient, seconds: Double, _ body: () async throws -> T) async throws -> T {
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timedOut = true
            client.close()
        }
        defer { watchdog.cancel() }
        return try await body()
    }

    package struct Launch {
        package init(executable: URL, arguments: [String], environment: [String: String]) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
        }

        package let executable: URL
        package let arguments: [String]
        package let environment: [String: String]
    }

    nonisolated package static func launch(for agent: ACPAgent, spawner: ProcessSpawner) throws -> Launch {
        var env = LoginShell.environment()
        // Cursor and Claude Code run ironpet's status hooks for chats started here too. The hook script skips this run.
        env["IRONPET_ACP_RUN"] = "1"
        guard let cli = LoginShell.find(agent.command) else { throw ACPLaunchError.cliMissing(agent.command) }
        guard let helper = agent.helper else {
            return Launch(executable: cli, arguments: agent.args, environment: env)
        }
        guard let adapter = ACPRuntime.adapterFile(helper.adapter) else { throw ACPLaunchError.adapterMissing(helper.adapter) }
        guard let runtime = ACPRuntime.resolve(adapter: helper.adapter, spawner: spawner) else { throw ACPLaunchError.runtimeMissing }
        env[helper.pathVariable] = cli.path
        return Launch(executable: runtime.executable, arguments: [adapter.path] + agent.args, environment: env)
    }

    private static var loggedVersions = Set<String>()

    /// Adapters pin one SDK version while the user's CLI can be older or newer, so the version belongs in the log.
    private func logCLIVersion() {
        guard agent.viaHelper, Self.loggedVersions.insert(agent.command).inserted, let cli = LoginShell.find(agent.command) else { return }
        let name = agent.command
        let spawner = spawner
        Task.detached {
            guard let process = try? spawner.spawn(ProcessSpec(executable: cli.path, arguments: ["--version"], error: .null)) else { return }
            let data = process.output?.readDataToEndOfFile() ?? Data()
            process.waitUntilExit()
            NSLog("ironpet: \(name) --version: \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Sessions

    /// The MCP servers this backend's sessions get: all of ironpet's for the chat, none for a restricted run.
    package var sessionMCPServers: [JSON] {
        guard !restricted else { return [] }
        let servers = mcpServers ?? Self.defaultMCPServers()
        guard let mcpCaller else { return servers }
        return servers.map { server in
            guard server["name"] as? String == "ironpet" else { return server }
            var named = server
            named["env"] = (server["env"] as? [JSON] ?? []) + [["name": MCPEndpoint.callerVariable, "value": mcpCaller]]
            return named
        }
    }
    /// Replaces `defaultMCPServers` for this backend's sessions, such as a background job's narrower set.
    package var mcpServers: [JSON]?

    /// The `_meta` the Claude Code adapter reads its tool rules from (`claudeCode.options`), or nil when the turn sets none.
    package nonisolated static func toolRulesMeta(_ turn: ACPTurn) -> JSON? {
        var options: JSON = [:]
        if let allowed = turn.allowedTools, !allowed.isEmpty { options["allowedTools"] = allowed }
        if let disallowed = turn.disallowedTools, !disallowed.isEmpty { options["disallowedTools"] = disallowed }
        return options.isEmpty ? nil : ["claudeCode": ["options": options]]
    }

    /// What a turn's `fork` request came to: `forked`, or `unsupported` with the reason the session started fresh.
    package enum ForkOutcome: Equatable { case forked, unsupported(String) }
    package private(set) var forkOutcome: ForkOutcome?

    private func ensureSession(_ turn: ACPTurn) async throws {
        guard let client else { throw ACPError(code: -1, message: "The agent stopped") }
        if sessionReady, sessionID != nil { return }
        // A new or reloaded session counts cost from its own start. A reload's replayed updates set the baseline again.
        reportedCost = nil
        costAccounted = nil
        costBaselineMissing = false
        var params: JSON = ["cwd": turn.workspace.path, "mcpServers": sessionMCPServers]
        if let meta = Self.toolRulesMeta(turn) { params["_meta"] = meta }
        let sessionCapabilities = capabilities["sessionCapabilities"] as? JSON ?? [:]
        if sessionCapabilities["additionalDirectories"] != nil, !restricted {
            let folders = ChatPreviewRoots.ironPetExtraFolders
            for dir in folders { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            params["additionalDirectories"] = folders.map(\.path)
        }
        if let source = turn.fork, sessionID == nil {
            if sessionCapabilities["fork"] == nil {
                forkOutcome = .unsupported("\(agent.name) does not advertise session/fork")
            } else {
                do {
                    let result = try await guarded(client, seconds: 60) {
                        try await client.request("session/fork", params.merging(["sessionId": source]) { $1 })
                    }
                    if let id = result["sessionId"] as? String {
                        sessionID = id
                        sessionReady = true
                        freshSession = false
                        forkOutcome = .forked
                        emit(.session(id))
                        await readSessionModes(result, when: "session/fork")
                        readModels(result)
                        return
                    }
                    forkOutcome = .unsupported("\(agent.name) returned no session for session/fork")
                } catch let error as ACPError where error.isAuthRequired || client.isClosed {
                    throw error
                } catch {
                    forkOutcome = .unsupported("session/fork failed: \(error.localizedDescription)")
                }
            }
        }
        if let existing = sessionID ?? turn.resume, capabilities["loadSession"] as? Bool == true {
            sessionID = existing
            replaying = true
            defer { replaying = false }
            do {
                var load = params
                load["sessionId"] = existing
                let result = try await guarded(client, seconds: 60) { try await client.request("session/load", load) }
                await readSessionModes(result, when: "session/load")
                readModels(result)
                sessionReady = true
                freshSession = false
                // What the session spent before this run is not this run's cost.
                costAccounted = reportedCost
                costBaselineMissing = reportedCost == nil
                return
            } catch let error as ACPError where error.isAuthRequired || client.isClosed {
                throw error
            } catch {
                NSLog("ironpet: \(agent.name) could not load session \(existing): \(error.localizedDescription). Starting a new one.")
                ChatLog.note("session/load failed for \(existing): \(error.localizedDescription). Starting a new agent session, transcript kept")
                sessionID = nil
            }
        }
        let result = try await guarded(client, seconds: 60) { try await client.request("session/new", params) }
        guard let id = result["sessionId"] as? String else { throw ACPError(code: -1, message: "The agent did not return a session") }
        sessionID = id
        sessionReady = true
        freshSession = true
        emit(.session(id))
        await readSessionModes(result, when: "session/new")
        readModels(result)
    }

    /// The mode to switch to at session start, or nil to leave the session in the mode the agent started in. Only the user's pick
    /// from the chat switches it, and only when the agent still advertises it. Jobs and automations have no pick and keep the agent's own mode.
    package nonisolated static func startMode(current: String?, available: [String], preferred: String?) -> String? {
        guard let preferred, preferred != current, available.contains(preferred) else { return nil }
        return preferred
    }

    private func readSessionModes(_ result: JSON, when event: String) async {
        let block = result["modes"] as? JSON
        modeID = block?["currentModeId"] as? String
        modes = (block?["availableModes"] as? [JSON] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return AgentMode(id: id, name: item["name"] as? String ?? id, detail: item["description"] as? String)
        }
        let target = Self.startMode(current: modeID, available: modes.map(\.id), preferred: preferredMode)
        var failure: String?
        if let target, let client, let sessionID {
            do {
                _ = try await client.request("session/set_mode", ["sessionId": sessionID, "modeId": target])
                modeID = target
            } catch {
                failure = error.localizedDescription
            }
        }
        let line = "\(agent.name) \(event): mode \(block?["currentModeId"] as? String ?? "none")" + (target.map { " -> \($0)" } ?? " kept")
            + ", now \(modeID ?? "none"), \(modes.count) advertised" + (failure.map { ", set_mode failed: \($0). It may run tools without asking." } ?? "")
        NSLog("ironpet: \(line)")
        ChatLog.note(line)
        onModes?(modeID, modes)
    }

    /// The user picked a mode for this agent. Saved by the caller; applied here at once when a session is open.
    package func setMode(_ id: String) async {
        preferredMode = id
        guard let client, let sessionID, sessionReady, modes.contains(where: { $0.id == id }), id != modeID else { return }
        do {
            _ = try await client.request("session/set_mode", ["sessionId": sessionID, "modeId": id])
            modeID = id
            ChatLog.note("\(agent.name): mode set to \(id) by the user")
        } catch {
            NSLog("ironpet: could not switch \(agent.name) to mode \(id): \(error.localizedDescription)")
        }
        onModes?(modeID, modes)
    }

    private func readModels(_ result: JSON) {
        models = []
        modelConfigID = nil
        if let block = result["models"] as? JSON, let list = block["availableModels"] as? [JSON] {
            models = list.compactMap { item in
                guard let id = item["modelId"] as? String else { return nil }
                return ChatModel(id: id, name: item["name"] as? String ?? id)
            }
            currentModel = block["currentModelId"] as? String
        } else if let options = result["configOptions"] as? [JSON],
                  let option = options.first(where: { $0["category"] as? String == "model" || $0["id"] as? String == "model" }) {
            modelConfigID = option["id"] as? String
            currentModel = option["currentValue"] as? String
            let entries = option["options"] as? [JSON] ?? []
            models = entries.flatMap { entry -> [JSON] in (entry["options"] as? [JSON]) ?? [entry] }.compactMap { item in
                guard let id = item["value"] as? String else { return nil }
                return ChatModel(id: id, name: item["name"] as? String ?? id)
            }
        }
        emit(.models(current: currentModel, models))
    }

    private func applyModel(_ wanted: String?) async {
        guard let client, let sessionID, let wanted, wanted != currentModel, models.contains(where: { $0.id == wanted }) else { return }
        do {
            if let modelConfigID {
                _ = try await client.request("session/set_config_option", ["sessionId": sessionID, "configId": modelConfigID, "value": wanted])
            } else {
                _ = try await client.request("session/set_model", ["sessionId": sessionID, "modelId": wanted])
            }
            currentModel = wanted
        } catch {
            NSLog("ironpet: could not switch \(agent.name) to \(wanted): \(error.localizedDescription)")
        }
    }

    // MARK: Prompt

    private func promptBlocks(_ turn: ACPTurn) -> [JSON] {
        var context: [String] = []
        var blocks: [JSON] = []
        let canSendImages = (capabilities["promptCapabilities"] as? JSON)?["image"] as? Bool == true
        var pathOnly: [URL] = []
        for image in turn.images {
            if canSendImages, let block = Self.imageBlock(image) { blocks.append(block) } else { pathOnly.append(image) }
        }
        if !pathOnly.isEmpty {
            context.append("Screenshot\(pathOnly.count > 1 ? "s" : "") of my screen (open and look at \(pathOnly.count > 1 ? "them" : "it") first): "
                + pathOnly.map(\.path).joined(separator: ", "))
        }
        if !turn.files.isEmpty {
            context.append("Attached file\(turn.files.count > 1 ? "s" : "") (read \(turn.files.count > 1 ? "them" : "it") first): "
                + turn.files.map(\.path).joined(separator: ", "))
        }
        var text = turn.prompt
        if !context.isEmpty { text = context.joined(separator: "\n") + "\n\n" + text }
        if freshSession, let preamble = turn.preamble { text = preamble + "\n" + text }
        freshSession = false
        return [["type": "text", "text": text]] + blocks
    }

    package nonisolated static func imageBlock(_ url: URL) -> JSON? {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        guard let mime = types[url.pathExtension.lowercased()], let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
        return ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
    }

    // MARK: Agent to client

    private func notification(_ method: String, _ params: JSON) {
        guard method == "session/update", params["sessionId"] as? String == sessionID,
              let update = params["update"] as? JSON else { return }
        // The command list is state, not history, so it also counts while the session replays.
        if update["sessionUpdate"] as? String == "available_commands_update" {
            emit(.commands(SlashCommand.parse(update["availableCommands"] as? [JSON] ?? [])))
            return
        }
        // So is the permission mode: the agent can change it itself.
        if update["sessionUpdate"] as? String == "current_mode_update", let id = update["currentModeId"] as? String {
            modeID = id
            onModes?(modeID, modes)
            return
        }
        // The session's running cost is state too: a reload replays it, and the replayed total is the baseline for new turns.
        if update["sessionUpdate"] as? String == "usage_update", let cost = update["cost"] as? JSON,
           let amount = (cost["amount"] as? NSNumber)?.doubleValue, let currency = cost["currency"] as? String {
            reportedCost = (amount, currency)
        }
        guard !replaying else { return }
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            // A subagent's own chatter is not part of the main reply.
            if ACPToolCall.parentID(in: update) != nil { return }
            if let content = update["content"] as? JSON, content["type"] as? String == "text", let text = content["text"] as? String, !text.isEmpty {
                emitTranscript(.assistant(text))
            }
        case "usage_update":
            // The Claude Code adapter names the model the usage belongs to, since `usage_update` has no field for it.
            if promptInFlight, let model = (update["_meta"] as? JSON)?["_claude/model"] as? String { modelReportedInTurn = model }
        case "tool_call":
            let call = ACPToolCall(json: update)
            tools[call.id] = call
            emitTool(call, .toolStarted(id: call.id, summary: call.summary))
            finishIfDone(update, call)
        case "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            var call = tools[id] ?? ACPToolCall(id: id)
            let before = call.summary
            call.merge(update)
            tools[id] = call
            if call.summary != before, !finishedTools.contains(id) { emitTool(call, .toolUpdated(id: id, summary: call.summary)) }
            finishIfDone(update, call)
        default:
            break
        }
    }

    private func finishIfDone(_ update: JSON, _ call: ACPToolCall) {
        guard let status = update["status"] as? String, status == "completed" || status == "failed", finishedTools.insert(call.id).inserted else { return }
        emitTool(call, .toolFinished(id: call.id, ok: status == "completed"))
    }

    private func agentRequest(_ method: String, _ params: JSON, _ respond: @escaping (Result<JSON, ACPError>) -> Void) {
        if method == "elicitation/create" { return elicit(params, respond) }
        guard method == "session/request_permission" else {
            return respond(.failure(ACPError(code: -32601, message: "ironpet does not provide \(method)")))
        }
        var call = ACPToolCall(json: params["toolCall"] as? JSON ?? [:])
        // The permission request often omits the arguments that the earlier tool_call carried.
        if let known = tools[call.id] {
            var merged = known
            merged.merge(params["toolCall"] as? JSON ?? [:])
            call = merged
        }
        let options = params["options"] as? [JSON] ?? []
        call.permissionOptions = options.compactMap(PermissionOption.init(json:))
        guard let onPermission else { return respond(.success(Self.outcome(.deny("ironpet is not ready"), options: options))) }
        let token = UUID()
        pendingPermissions[token] = respond
        onPermission(call) { [weak self] decision in
            guard let self, let pending = self.pendingPermissions.removeValue(forKey: token) else { return }
            pending(.success(Self.outcome(decision, options: options)))
        }
    }

    private func elicit(_ params: JSON, _ respond: @escaping (Result<JSON, ACPError>) -> Void) {
        guard let form = ElicitationForm.parse(params) else {
            ChatLog.note("declined an elicitation ironpet cannot draw: mode \(params["mode"] as? String ?? "none")")
            return respond(.success(ElicitationReply.decline.json))
        }
        guard let onElicitation else { return respond(.success(ElicitationReply.decline.json)) }
        let token = UUID()
        pendingElicitations[token] = respond
        onElicitation(form) { [weak self] reply in
            guard let self, let pending = self.pendingElicitations.removeValue(forKey: token) else { return }
            pending(.success(reply.json))
        }
    }

    /// The option the user chose, when the agent offered it. Otherwise the offered option that matches an allow or deny: allow_once or
    /// reject_once first.
    package nonisolated static func outcome(_ decision: ApprovalDecision, options: [JSON]) -> JSON {
        if let chosen = decision.optionID, options.contains(where: { $0["optionId"] as? String == chosen }) {
            return ["outcome": ["outcome": "selected", "optionId": chosen]]
        }
        let wanted = decision.allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        for kind in wanted {
            if let option = options.first(where: { $0["kind"] as? String == kind }), let id = option["optionId"] as? String {
                return ["outcome": ["outcome": "selected", "optionId": id]]
            }
        }
        return ["outcome": ["outcome": "cancelled"]]
    }
}

/// Which catalog agents the user has and which of them speak ACP.
package enum ACPProbe {
    private static var answered: [String: Bool] = [:]

    /// Native agents must answer `initialize`; adapter-backed agents count as present when their CLI is installed,
    /// because the adapter answers for them.
    @MainActor
    package static func installed(spawner: ProcessSpawner) async -> [ACPAgent] {
        let present = AgentCatalog.present()
        var result: [ACPAgent] = []
        await withTaskGroup(of: (ACPAgent, Bool).self) { group in
            for agent in present {
                if agent.viaHelper { result.append(agent); continue }
                group.addTask { (agent, await answersInitialize(agent, spawner: spawner)) }
            }
            for await (agent, ok) in group where ok { result.append(agent) }
        }
        return AgentCatalog.all.filter { agent in result.contains { $0.id == agent.id } }
    }

    @MainActor
    package static func answersInitialize(_ agent: ACPAgent, spawner: ProcessSpawner) async -> Bool {
        guard let exe = LoginShell.find(agent.command) else { return false }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(exe.path):\(stamp)"
        if let known = answered[key] { return known }
        var env = LoginShell.environment()
        env["IRONPET_ACP_RUN"] = "1"
        let transport = ACPProcessTransport(executable: exe, arguments: agent.args, environment: env, directory: FileManager.default.temporaryDirectory,
                                            spawner: spawner)
        let client = ACPClient(transport: transport)
        guard (try? client.start()) != nil else { return false }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { client.close() }
        }
        defer { watchdog.cancel(); client.close() }
        let ok = (try? await client.request("initialize", ["protocolVersion": 1, "clientCapabilities": JSON()])) != nil
        if ok { answered[key] = true }
        return ok
    }
}
