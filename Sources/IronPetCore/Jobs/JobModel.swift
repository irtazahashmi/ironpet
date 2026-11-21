import Foundation

package enum JobState: String, CaseIterable {
    /// Waiting for a free slot (`jobs.maxRunning`).
    case queued
    case running
    /// A command or tool call waits for Allow or Deny.
    case needsApproval = "needs_approval"
    case done
    case failed
    /// The user stopped it.
    case stopped
    /// ironpet quit while it was queued or running.
    case interrupted

    /// Queued or running: it holds, or waits for, an agent process.
    package var isActive: Bool { self == .queued || self == .running || self == .needsApproval }
}

/// Work an agent handed off to its own agent session (`jobs_start`). It runs in the background in one folder, with the
/// chat's agent and model, and is tracked by a task. Its transcript is saved as a thread, so the user can read it or
/// carry on in the chat.
package struct Job: Identifiable, Equatable {
    package init(
        id: String,
        title: String,
        prompt: String,
        folder: String,
        agent: String,
        model: String? = nil,
        thread: String? = nil,
        task: String? = nil,
        state: JobState = .queued,
        lastStep: String? = nil,
        summary: String? = nil,
        error: String? = nil,
        waitingFor: String? = nil,
        created: Date,
        started: Date? = nil,
        ended: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.folder = folder
        self.agent = agent
        self.model = model
        self.thread = thread
        self.task = task
        self.state = state
        self.lastStep = lastStep
        self.summary = summary
        self.error = error
        self.waitingFor = waitingFor
        self.created = created
        self.started = started
        self.ended = ended
    }

    package let id: String
    package var title: String
    package var prompt: String
    package var folder: String
    /// Catalog id of the agent that runs it.
    package var agent: String
    package var model: String?
    /// The agent's session id, which is also the saved thread's id. Nil until the session starts.
    package var thread: String?
    /// The task that tracks it in the Tasks section.
    package var task: String?
    package var state: JobState = .queued
    /// What the agent did last, such as "Run swift test".
    package var lastStep: String?
    /// The first sentence of the final reply.
    package var summary: String?
    package var error: String?
    /// The approval it waits for, while `needsApproval`.
    package var waitingFor: String?
    package var created: Date
    package var started: Date?
    package var ended: Date?

    package static let titleLimit = 120
    package static let promptLimit = 20_000

    package static func makeID() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "job-" + String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// The row in the Agents section and the attention bubbles. Stopped and interrupted jobs are not listed.
    package var agentSession: AgentSession? {
        let status: AgentStatus
        switch state {
        case .queued, .running: status = .running
        case .needsApproval: status = .needsInput
        case .done: status = .done
        case .failed: status = .failed
        case .stopped, .interrupted: return nil
        }
        var session = AgentSession(id: Self.sessionKey(id), source: .job, status: status, prompt: title)
        session.origin.workspace = folder
        session.detail = waitingFor.map { "Wants to: \($0)" } ?? (state == .queued ? "Waiting to start" : error ?? lastStep)
        session.lastResponse = summary
        session.updatedAt = ended ?? started ?? created
        session.turnStartedAt = started ?? created
        return session
    }

    /// `job:<id>`, the key of the job's row in `SessionStore`.
    package static func sessionKey(_ id: String) -> String { "\(AgentSource.job.rawValue):\(id)" }

    /// The job id in a `SessionStore` key, or nil for a session that is not a job.
    package static func id(fromSessionKey key: String) -> String? {
        let prefix = AgentSource.job.rawValue + ":"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    package var json: [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = ["id": id, "title": title, "state": state.rawValue, "folder": folder, "agent": agent,
                                     "created": iso.string(from: created)]
        object["model"] = model
        object["thread"] = thread
        object["task"] = task
        object["last_step"] = lastStep
        object["summary"] = summary
        object["error"] = error
        object["waiting_for"] = waitingFor
        object["started"] = started.map(iso.string(from:))
        object["ended"] = ended.map(iso.string(from:))
        return object
    }
}
