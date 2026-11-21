import Foundation
#if canImport(Combine)
import Combine
#endif

/// The agent sessions Ghost watches (Cursor, Claude Code, Codex and others), folded from their hook events.
@MainActor
package final class AgentsAPI {
    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    private let store: SessionStore
    private var forwarding: [ChangeToken] = []

    /// Brings the session's terminal or editor to the front. Only the Mac can do this, so the app owner sets it.
    package var focusHandler: ((AgentSession) -> Void)?
    /// Starts a conversation about a session: shows the chat with a prompt about it in the input. The app owner sets it.
    package var askHandler: ((String) -> Void)?

    package init(store: SessionStore) {
        self.store = store
        forwarding = [
            store.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    /// Sessions that are not idle, most urgent first.
    package var sessions: [AgentSession] { store.ordered }
    /// The most urgent status and how many sessions share it.
    package var summary: (status: AgentStatus, count: Int) { store.summary }

    package func list() -> [AgentSession] { store.ordered }

    package func get(_ id: String) throws -> AgentSession {
        guard let session = store.sessions[id] else { throw APIError.notFound("no session with id \"\(id)\"") }
        return session
    }

    /// Marks a finished or failed session as seen.
    package func acknowledge(_ id: String) throws {
        _ = try get(id)
        store.acknowledge(id)
    }

    package func acknowledgeAll() { store.acknowledgeAll() }

    /// Jumps to the session's terminal or editor, and marks it seen.
    package func focus(_ id: String) throws {
        let session = try get(id)
        guard let focusHandler else { throw APIError.unavailable("this device cannot open the session's window") }
        focusHandler(session)
    }

    /// Asks Ghost about a session: what it did, or why it needs input.
    package func ask(_ id: String) throws {
        let session = try get(id)
        guard let askHandler else { throw APIError.unavailable("the chat is not available") }
        askHandler(Self.prompt(for: session))
    }

    package static func prompt(for session: AgentSession) -> String {
        "What is going on with the \(session.source.displayName) session in \(session.workspaceName)? It is \(session.status.label.lowercased())."
    }
}

#if canImport(Combine)

extension AgentsAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
