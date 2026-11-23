import Foundation

/// Runs a `prompt` action. It gets its own agent process and session in `~/.ironpet/automations/workspace`, so the
/// user's chat keeps its thread, folder and agent. Only read-only tool calls are allowed.
@MainActor
package enum AutomationPrompt {
    /// The catalog id of the agent a background run of this automation uses: its own `agent`, else the chat's, else Cursor.
    package static func agentID(_ automation: Automation, defaults: UserDefaults = .standard) -> String {
        if let id = automation.action.agent, AgentCatalog.agent(id: id) != nil { return id }
        return ChatAgentPreference.resolveID(defaults: defaults)
    }

    /// `agentOverride` lets tests run a scripted agent instead of one from the catalog.
    /// Only what reads. This run carries outside item text, so even Ghost's memory notes, which a chat may edit without a card, are
    /// refused: they reach every new chat's preamble.
    package nonisolated static func decision(for call: ACPToolCall) -> ApprovalDecision {
        if case .allow = ApprovalRules.policy(for: call, isMemoryFile: { _ in false }) { return .allow }
        return .deny("Automations can only read")
    }

    package static func run(_ automation: Automation, prompt: String, workspace: URL, spawner: ProcessSpawner, timeout: TimeInterval = 300,
                    agentOverride: ACPAgent? = nil) async -> Result<String, AutomationError> {
        guard let agent = agentOverride ?? AgentCatalog.agent(id: agentID(automation)) else {
            return .failure(.init(message: "no agent is available"))
        }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let runner = ACPBackend(agent: agent, spawner: spawner)
        runner.restricted = true
        runner.usageFeature = .automations
        runner.onPermission = { call, respond in respond(decision(for: call)) }
        let text = "This is an automated run of \"\(automation.name)\" from ironpet. Answer in under 600 characters, as plain text for a small notification.\n\n\(prompt)"
        let turn = ACPTurn(prompt: text, preamble: nil, workspace: workspace, resume: nil, model: automation.action.model, images: [], files: [])
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
