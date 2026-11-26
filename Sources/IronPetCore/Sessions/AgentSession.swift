import Foundation

package enum AgentSource: String, Codable {
    case cursor, claude, codex, gemini, copilot, pi
    /// A background job ironpet runs itself (`JobService`), not a session a hook reported.
    case job

    package var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .copilot: return "GitHub Copilot"
        case .pi: return "Pi"
        case .job: return "Background job"
        }
    }
}

/// Ordered by how urgently the pet should surface it.
package enum AgentStatus: Int, Comparable, Codable {
    case idle, running, done, failed, needsInput

    package static func < (a: AgentStatus, b: AgentStatus) -> Bool { a.rawValue < b.rawValue }

    package var label: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        case .needsInput: return "Needs input"
        }
    }

    package var mood: PetMood {
        switch self {
        case .idle: return .idle
        case .running: return .working
        case .done: return .done
        case .failed: return .failed
        case .needsInput: return .needsInput
        }
    }
}

/// Where the hook ran, used to jump back to the session.
package struct SessionOrigin: Codable {
    package init(
        workspace: String? = nil,
        termProgram: String? = nil,
        itermSessionID: String? = nil,
        pid: Int32? = nil,
        ownerBundleID: String? = nil,
        cmuxWorkspaceID: String? = nil,
        cmuxSurfaceID: String? = nil,
        t3ThreadID: String? = nil,
        herdrTerminalID: String? = nil,
        orcaTerminalHandle: String? = nil
    ) {
        self.workspace = workspace
        self.termProgram = termProgram
        self.itermSessionID = itermSessionID
        self.pid = pid
        self.ownerBundleID = ownerBundleID
        self.cmuxWorkspaceID = cmuxWorkspaceID
        self.cmuxSurfaceID = cmuxSurfaceID
        self.t3ThreadID = t3ThreadID
        self.herdrTerminalID = herdrTerminalID
        self.orcaTerminalHandle = orcaTerminalHandle
    }

    package var workspace: String?
    package var termProgram: String?
    package var itermSessionID: String?
    /// The agent's process id as the hook saw it.
    package var pid: Int32?
    /// Bundle id of the app that started the agent, resolved from `pid` when the first event arrived.
    package var ownerBundleID: String?
    /// Ids the hosting app put in the agent's environment, used to open the exact tab or thread. Only these
    /// variables are kept; see `AppIDs`.
    package var cmuxWorkspaceID: String?
    package var cmuxSurfaceID: String?
    package var t3ThreadID: String?
    package var herdrTerminalID: String?
    package var orcaTerminalHandle: String?
}

/// The only environment variables the hook forwards besides the terminal ones. Everything else stays out.
package enum AppIDs {
    /// Environment variable and the header the hook script sends it in.
    package static let headers: [(env: String, header: String)] = [
        ("CMUX_WORKSPACE_ID", "x-ironpet-cmux-workspace"),
        ("CMUX_SURFACE_ID", "x-ironpet-cmux-surface"),
        ("T3CODE_THREAD_ID", "x-ironpet-t3-thread"),
        ("HC_TERMINAL_ID", "x-ironpet-herdr-terminal"),
        ("ORCA_TERMINAL_HANDLE", "x-ironpet-orca-terminal"),
    ]

    /// An id is kept when it is non-empty, short and has no control characters. Other characters are fine: the
    /// openers percent-encode ids in URLs and pass them as one argument to commands.
    package static func clean(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 200,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return raw
    }

    /// Reads the five ids from an environment, ignoring every other variable.
    package static func capture(env: [String: String]) -> SessionOrigin {
        var origin = SessionOrigin()
        origin.cmuxWorkspaceID = clean(env["CMUX_WORKSPACE_ID"])
        origin.cmuxSurfaceID = clean(env["CMUX_SURFACE_ID"])
        origin.t3ThreadID = clean(env["T3CODE_THREAD_ID"])
        origin.herdrTerminalID = clean(env["HC_TERMINAL_ID"])
        origin.orcaTerminalHandle = clean(env["ORCA_TERMINAL_HANDLE"])
        return origin
    }
}

package struct AgentSession: Identifiable, Codable {
    package init(
        id: String,
        source: AgentSource,
        status: AgentStatus = .idle,
        prompt: String? = nil,
        detail: String? = nil,
        origin: SessionOrigin = SessionOrigin(),
        ended: Bool = false,
        updatedAt: Date = Date(),
        turnStartedAt: Date = Date(),
        editedFiles: [String] = [],
        lastResponse: String? = nil,
        agentId: String? = nil
    ) {
        self.id = id
        self.source = source
        self.status = status
        self.prompt = prompt
        self.detail = detail
        self.origin = origin
        self.ended = ended
        self.updatedAt = updatedAt
        self.turnStartedAt = turnStartedAt
        self.editedFiles = editedFiles
        self.lastResponse = lastResponse
        self.agentId = agentId
    }

    package let id: String
    package let source: AgentSource
    package var status: AgentStatus = .idle
    package var prompt: String?
    package var detail: String?
    package var origin = SessionOrigin()
    package var ended = false
    package var updatedAt = Date()
    package var turnStartedAt = Date()
    /// Files edited during the current turn, in order.
    package var editedFiles: [String] = []
    /// The agent's last reply in the current turn.
    package var lastResponse: String?
    /// The id of the agent that launched the session. Nil when no hook said, which is agent 1.
    package var agentId: String?

    /// The owning agent's id, with a missing one read as agent 1.
    package var ownerAgentID: String { AgentOwner.id(agentId) }

    package var workspaceName: String {
        guard let path = origin.workspace, !path.isEmpty else { return "Unknown workspace" }
        if path == "/" { return "No project" }
        if path == NSHomeDirectory() { return "Home" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// One line about what the turn did, e.g. "Edited 3 files · Fixed the flaky login test."
    package var summary: String? {
        var parts: [String] = []
        if let only = editedFiles.first, editedFiles.count == 1 {
            parts.append("Edited \(URL(fileURLWithPath: only).lastPathComponent)")
        } else if !editedFiles.isEmpty {
            parts.append("Edited \(editedFiles.count) files")
        }
        if let sentence = lastResponse.flatMap(Self.firstSentence) { parts.append(sentence) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    package mutating func startTurn() {
        turnStartedAt = Date()
        editedFiles = []
        lastResponse = nil
    }

    package mutating func noteEdit(_ path: String?) {
        guard let path, !path.isEmpty, !editedFiles.contains(path) else { return }
        editedFiles.append(path)
    }

    package static func firstSentence(_ text: String) -> String? {
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        guard let line = plain.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-* ").union(.whitespaces)) })
            .first(where: { !$0.isEmpty }) else { return nil }
        var sentence = line
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            sentence = String(line[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return sentence.count > 140 ? String(sentence.prefix(137)) + "…" : sentence
    }

    /// The agent's own session id, without the `<source>:` prefix of the store key.
    package var agentSessionID: String? {
        let prefix = source.rawValue + ":"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        return rest.isEmpty ? nil : rest
    }

    package var isInIterm: Bool { origin.itermSessionID?.isEmpty == false }
}
