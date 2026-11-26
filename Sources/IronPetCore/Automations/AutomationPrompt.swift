import Foundation

/// Runs a `prompt` action. It gets its own agent process and session in `~/.ironpet/automations/workspace`, so the
/// user's chat keeps its thread, folder and agent. Only read-only tool calls are allowed.
@MainActor
package enum AutomationPrompt {
    /// What a run of an automation uses: the CLI, the model and the permissions of the agent that owns it.
    package struct Runtime: Equatable {
        /// The catalog id of the agent CLI.
        package var cli: String
        /// The model to ask for. Nil uses the CLI's own default.
        package var model: String?
        /// The owner's tool permissions by tool rule, each `allow` or `deny`.
        package var permissions: [String: String]
    }

    /// The runtime an automation runs on. The CLI is the action's own `agent`, else the owner's, else the chat's, else Cursor. The model
    /// is the action's own `model`, else the owner's when the run uses the owner's CLI. Agent 1's model is the chat's and automations have
    /// never used it, so agent 1 keeps the CLI's default. A node-level automation has no owner and runs on agent 1's CLI, as it always has.
    package static func runtime(for automation: Automation, registry: AgentRegistry? = nil, defaults: UserDefaults = .standard) -> Runtime {
        let registry = registry ?? AgentRegistry.live
        let owner = automation.ownerAgentID ?? AgentOwner.defaultID
        let record = registry?.get(owner)
        let cli: String
        if let id = automation.action.agent, AgentCatalog.agent(id: id) != nil {
            cli = id
        } else if let id = record?.agentCli, AgentCatalog.agent(id: id) != nil {
            cli = id
        } else {
            cli = ChatAgentPreference.resolveID(defaults: defaults)
        }
        var model = automation.action.model
        if model == nil, owner != AgentOwner.defaultID, record?.agentCli == cli { model = record?.model }
        return Runtime(cli: cli, model: model, permissions: automation.ownerAgentID == nil ? [:] : record?.permissions ?? [:])
    }

    /// The catalog id of the agent a background run of this automation uses: its own `agent`, else its owner's, else the chat's, else Cursor.
    package static func agentID(_ automation: Automation, defaults: UserDefaults = .standard) -> String {
        runtime(for: automation, defaults: defaults).cli
    }

    /// What the owner's permissions say about a call: `deny` when a rule that is `deny` matches, `allow` when one that is `allow` does, and
    /// nil when no rule matches. A rule is a tool name, as in an automation's `allowedTools`.
    package nonisolated static func ownerVerdict(_ permissions: [String: String], for call: ACPToolCall) -> ApprovalDecision? {
        let rules = permissions.sorted { $0.key < $1.key }
        if rules.contains(where: { $0.value == "deny" && ToolRule.matches($0.key, call) }) { return .deny("This agent may not use that tool") }
        if rules.contains(where: { $0.value == "allow" && ToolRule.matches($0.key, call) }) { return .allow }
        return nil
    }

    /// `agentOverride` lets tests run a scripted agent instead of one from the catalog.
    /// Only what reads. This run carries outside item text, so even Ghost's memory notes, which a chat may edit without a card, are
    /// refused: they reach every new chat's preamble.
    package nonisolated static func decision(for call: ACPToolCall, permissions: [String: String] = [:]) -> ApprovalDecision {
        // An owner's refusal holds here too. Its `allow` does not widen what this read-only run may do.
        if let verdict = ownerVerdict(permissions, for: call), !verdict.allow { return verdict }
        if case .allow = ApprovalRules.policy(for: call) { return .allow }
        return .deny("Automations can only read")
    }

    package static func run(_ automation: Automation, prompt: String, workspace: URL, spawner: ProcessSpawner, timeout: TimeInterval = 300,
                    agentOverride: ACPAgent? = nil, registry: AgentRegistry? = nil) async -> Result<String, AutomationError> {
        let runtime = runtime(for: automation, registry: registry)
        guard let agent = agentOverride ?? AgentCatalog.agent(id: runtime.cli) else {
            return .failure(.init(message: "no agent is available"))
        }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let runner = ACPBackend(agent: agent, spawner: spawner)
        runner.restricted = true
        runner.usageFeature = .automations
        runner.onPermission = { call, respond in respond(decision(for: call, permissions: runtime.permissions)) }
        let text = Prompts.render(id: "automation-prompt", ["name": automation.name, "prompt": prompt])
        let turn = ACPTurn(prompt: text, preamble: nil, workspace: workspace, resume: nil, model: runtime.model, images: [], files: [])
        let state = Box()
        let task = Task { @MainActor in
            await runner.runTurn(turn) { event in
                switch event {
                case .assistant(let chunk): state.answer += chunk
                case .finished(let error): state.finish(error.map { .failure(.init(message: $0)) } ?? .success(state.answer))
                case .needsSignIn: state.finish(.failure(.init(message: "\(agent.name) needs you to sign in. Open it in the chat once, then try again.")))
                case .needsRuntime: state.finish(.failure(.init(message: "\(agent.name) needs Node 22 or Bun. Open it in the chat once to set that up.")))
                default: break
                }
            }
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            state.finish(.failure(.init(message: "The agent did not answer within \(Int(timeout)) seconds.")))
        }
        let result = await state.wait()
        watchdog.cancel()
        task.cancel()
        runner.cancel()
        runner.shutdown()
        return result
    }

    @MainActor
    package final class Box {
        package init() {}

        package var answer = ""
        private var result: Result<String, AutomationError>?
        private var continuation: CheckedContinuation<Result<String, AutomationError>, Never>?

        package func finish(_ value: Result<String, AutomationError>) {
            guard result == nil else { return }
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }

        package func wait() async -> Result<String, AutomationError> {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
    }
}
