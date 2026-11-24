import Foundation

/// Runs a `prompt` action with `session` set to `new` or `own`. The run gets its own agent process with the agent's full
/// tools minus the action's `disallowedTools`, and is saved as a thread marked as an automation run, so the user can open
/// it from the thread list. It never touches the open chat.
///
/// `new` starts a fresh agent session every run. `own` resumes the thread this automation used last. When the agent's
/// session transcript passes `chat.sessionRolloverMB`, the next run first asks the old session for a handoff summary and
/// then continues in a fresh agent session, in the same thread, with the memory preamble, the summary and the last
/// messages. An agent whose transcript file is unknown (anything but Claude Code) starts a fresh thread after
/// `ownRunLimit` runs instead.
@MainActor
package enum AutomationSession {
    /// Runs one `own` thread of an agent without a known transcript file holds before the next run starts a fresh thread:
    /// `automations.ownRunLimit`.
    package static var ownRunLimit: Int { ConfigStore.shared.config.automations.ownRunLimit }

    /// Nobody is there to answer, so anything that would ask is refused. Edits to Ghost's memory files are refused too: what an
    /// automation learns goes through the memory tools, which mark it as coming from the automation.
    package nonisolated static func decision(for call: ACPToolCall) -> ApprovalDecision {
        if ["edit", "delete", "move"].contains(call.kind), call.allPaths.contains(where: LegacyMemoryFiles.contains) {
            return .deny("Automations may not edit Ghost's memory files")
        }
        if case .allow = ApprovalRules.policy(for: call) { return .allow }
        return .deny("This automation runs without anyone to ask")
    }
    /// What an automation's own session does with a permission request. `allowedTools` and `disallowedTools` apply first: an allowed
    /// tool is answered with allow and a disallowed one with a refusal, and neither raises an alert. Anything else the agent
    /// asks about waits for the user.
    package enum Route { case answer(ApprovalDecision), ask }

    package nonisolated static func route(for call: ACPToolCall, allowed: [String]?, disallowed: [String]?) -> Route {
        if ["edit", "delete", "move"].contains(call.kind), call.allPaths.contains(where: LegacyMemoryFiles.contains) {
            return .answer(.deny("Automations may not edit Ghost's memory files"))
        }
        if let disallowed, disallowed.contains(where: { ToolRule.matches($0, call) }) { return .answer(.deny("This automation may not use that tool")) }
        if let allowed, allowed.contains(where: { ToolRule.matches($0, call) }) { return .answer(.allow) }
        if case .allow = ApprovalRules.policy(for: call) { return .answer(.allow) }
        return .ask
    }

    /// Threads kept per automation (`automations.keptThreads`). Older ones are deleted after a run.
    package static var keptThreads: Int { ConfigStore.shared.config.automations.keptThreads }

    package typealias TurnRunner = (ACPTurn, @escaping (AgentEvent) -> Void) async -> Void

    /// `agentOverride` and `turnRunner` let tests run a scripted agent.
    package static func run(_ automation: Automation, prompt: String, workspace: URL, spawner: ProcessSpawner, timeout: TimeInterval? = nil,
                    agentOverride: ACPAgent? = nil, turnRunner: TurnRunner? = nil, now: Date = Date(),
                    fork: String? = nil, onNote: ((String) -> Void)? = nil, permissions: BackgroundPermissions? = nil,
                    rolloverLimit: Int64? = nil, handoffTimeout: Duration = .seconds(90)) async -> Result<String, AutomationError> {
        guard let agent = agentOverride ?? AgentCatalog.agent(id: AutomationPrompt.agentID(automation)) else {
            return .failure(.init(message: "no agent is available"))
        }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var earlier: ChatThread?
        if automation.action.effectiveSession == "own", let last = ThreadStore.latest(automation: automation.id), last.agent == agent.id,
           agent.id == AgentTranscript.supportedAgent || (last.runs ?? 0) < ownRunLimit {
            earlier = last
        }

        let owner = "automation-run:\(UUID().uuidString)"
        defer { permissions?.end(owner: owner) }
        func makeBackend() -> ACPBackend {
            let created = ACPBackend(agent: agent, spawner: spawner)
            created.usageFeature = .automations
            created.mcpCaller = "automation:\(automation.id)"
            created.onPermission = { call, respond in
                switch Self.route(for: call, allowed: automation.action.allowedTools, disallowed: automation.action.disallowedTools) {
                case .answer(let decision): respond(decision)
                case .ask:
                    guard let permissions else { return respond(.deny("This automation runs without anyone to ask")) }
                    permissions.ask(owner: owner, source: "Automation \"\(automation.name)\"", call: call, respond: respond,
                                    timedOut: { onNote?($0) })
                }
            }
            return created
        }

        // Rollover: the old session's transcript is over the limit, or an earlier run rolled over and never reached the new session.
        var resume = earlier?.activeSession
        var handoff: String?
        var rolledFrom: String?
        if let earlier {
            if let active = earlier.activeSession {
                let limit = rolloverLimit ?? Int64(Config.load().config.chat.sessionRolloverMB) * 1_048_576
                if let bytes = AgentTranscript.size(agent: agent.id, workspace: workspace.path, session: active), bytes > limit {
                    let probe = ACPTurn(prompt: SessionHandoff.prompt, preamble: nil, workspace: workspace, resume: active,
                                        model: automation.action.model, images: [], files: [], allowedTools: [], disallowedTools: nil)
                    let summary = await requestHandoff(probe, timeout: handoffTimeout, turnRunner: turnRunner, backend: turnRunner == nil ? makeBackend() : nil)
                    handoff = SessionHandoff.compose(summary: SessionHandoff.clean(summary) ?? SessionHandoff.fallbackSummary(items: earlier.items), items: earlier.items)
                    rolledFrom = active
                    resume = nil
                    ChatLog.note("session rollover: automation \(automation.id) left session \(active) (\(bytes) bytes)")
                }
            } else {
                handoff = earlier.handoff
            }
        }
        // The prompt goes in as written: a slash skill such as `/am-check-emails 1` only works as the first thing in the message.
        var preamble: String?
        if let handoff {
            preamble = SessionHandoff.insert(handoff, into: MemoryPreamble.build(store: EntityMemoryStore.shared, workspace: workspace, firstMessage: prompt))
        }
        let turn = ACPTurn(prompt: prompt, preamble: preamble, workspace: workspace, resume: resume, model: automation.action.model,
                           images: [], files: [], allowedTools: automation.action.allowedTools, disallowedTools: automation.action.disallowedTools, fork: fork)

        var backend: ACPBackend?
        var run = turnRunner
        if run == nil {
            let created = makeBackend()
            backend = created
            run = { turn, emit in await created.runTurn(turn, onEvent: emit) }
        }

        let state = AutomationPrompt.Box()
        var sessionID: String?
        var transcript = TranscriptRecorder()
        let task = Task { @MainActor in
            await run?(turn) { event in
                transcript.record(event)
                switch event {
                case .session(let id): sessionID = id
                case .assistant(let chunk): state.answer += chunk
                case .finished(let error): state.finish(error.map { .failure(.init(message: $0)) } ?? .success(state.answer))
                case .needsSignIn: state.finish(.failure(.init(message: "\(agent.name) needs you to sign in. Open it in the chat once, then try again.")))
                case .needsRuntime: state.finish(.failure(.init(message: "\(agent.name) needs Node 22 or Bun. Open it in the chat once to set that up.")))
                default: break
                }
            }
        }
        // `automations.runTimeoutSeconds` unless a test passes its own.
        let limit = timeout ?? TimeInterval(ConfigStore.shared.config.automations.runTimeoutSeconds)
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            state.finish(.failure(.init(message: "The agent did not finish within \(Int(limit / 60)) minutes.")))
        }
        let result = await state.wait()
        watchdog.cancel()
        task.cancel()
        sessionID = sessionID ?? backend?.sessionID ?? resume
        if case .unsupported(let why)? = backend?.forkOutcome { onNote?("fork not supported by \(agent.name), ran as new (\(why))") }
        backend?.cancel()
        backend?.shutdown()
        // A forked run copies the chat's whole transcript. Once the run is over, nothing resumes that copy, so it goes.
        // Only the run's own session id is named: never the one it forked from, and nothing is listed or globbed.
        if let fork, let copy = sessionID, copy != fork, backend == nil || backend?.forkOutcome == .forked {
            AgentTranscript.delete(agent: agent.id, workspace: workspace.path, session: copy)
        }

        if case .failure(let error) = result { transcript.append(.init(kind: .error(error.message))) }
        let items = transcript.items
        if let sessionID {
            // The thread keeps its id (the first session's) through a rollover, so memory search hits stay valid.
            let resumed = earlier.flatMap { handoff != nil || $0.activeSession == sessionID ? $0 : nil }
            let threadID = resumed?.id ?? sessionID
            let first = ChatSession.Item(kind: .user(prompt), origin: ChatSession.automationOrigin)
            let marker = rolledFrom == nil ? [] : [ChatSession.Item(kind: .notice(SessionHandoff.systemLine))]
            var previous = resumed?.previousSessions ?? []
            if let rolledFrom { previous.append(rolledFrom) }
            ThreadStore.save(ChatThread(id: threadID, title: automation.name, workspace: workspace.path, updatedAt: now,
                                        items: (resumed?.items ?? []) + marker + [first] + items, agent: agent.id,
                                        automation: automation.id, automationName: automation.name, runs: (resumed?.runs ?? 0) + 1,
                                        session: sessionID == threadID ? nil : sessionID,
                                        previousSessions: previous.isEmpty ? nil : previous))
            ThreadStore.prune(automation: automation.id, keep: keptThreads)
            if rolledFrom != nil { AgentTranscript.pruneInBackground() }
        }
        return result
    }

    /// Asks the old session for its handoff summary in a turn of its own. Nil when it fails or times out.
    private static func requestHandoff(_ turn: ACPTurn, timeout: Duration, turnRunner: TurnRunner?, backend: ACPBackend?) async -> String? {
        let collector = HandoffCollector()
        let summary: String? = await withCheckedContinuation { continuation in
            collector.wait(timeout: timeout, continuation)
            Task { @MainActor in
                if let turnRunner {
                    await turnRunner(turn) { collector.receive($0) }
                } else {
                    await backend?.runTurn(turn) { collector.receive($0) }
                }
            }
        }
        backend?.cancel()
        backend?.shutdown()
        return summary
    }
}

/// Matches the `allowedTools` and `disallowedTools` entries of an automation (`Bash`, `Bash(git status:*)`, `mcp__github`) to a call.
package enum ToolRule {
    package nonisolated static func matches(_ rule: String, _ call: ACPToolCall) -> Bool {
        let rule = rule.trimmingCharacters(in: .whitespaces)
        var name = rule
        var argument: String?
        if let open = rule.firstIndex(of: "("), rule.hasSuffix(")") {
            name = String(rule[..<open])
            argument = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        }
        // Agents that send no tool name still say what kind of call it is.
        let names: [String]
        if let toolName = call.toolName { names = [toolName] } else {
            switch call.kind {
            case "execute": names = ["Bash"]
            case "edit": names = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
            case "read": names = ["Read"]
            case "search": names = ["Grep", "Glob"]
            case "fetch": names = ["WebFetch", "WebSearch"]
            default: names = [call.title]
            }
        }
        guard names.contains(where: { $0 == name || $0.hasPrefix(name + "__") }) else { return false }
        guard let argument else { return true }
        var wanted = argument
        for suffix in [":*", "*"] where wanted.hasSuffix(suffix) { wanted.removeLast(suffix.count); break }
        let actual = call.kind == "execute" ? call.command : (call.path ?? call.arguments)
        return actual.hasPrefix(wanted)
    }
}
