import Foundation
#if canImport(Combine)
import Combine
#endif

/// Alerts: what automations reported and left open until the user or the automation closes them.
@MainActor
final class AlertsAPI {
    /// Fires before anything this API reads changes.
    let changes = ChangeSignal()
    private let store: SignalStore
    private var forwarding: [ChangeToken] = []

    /// Starts a conversation about an alert: shows the chat with the alert's prompt in the input. The app owner sets it.
    var askHandler: ((String) -> Void)?

    init(store: SignalStore) {
        self.store = store
        forwarding = [
            store.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    /// Open alerts, newest first.
    var alerts: [Signal] { store.signals }

    /// The most urgent mood among open alerts and how many share it. Nil when none are open.
    var summary: (mood: PetMood, count: Int)? { store.summary }

    func list() -> [Signal] { store.signals }

    func get(_ id: String) throws -> Signal {
        guard let alert = store.signals.first(where: { $0.id == id }) else { throw APIError.notFound("no alert with id \"\(id)\"") }
        return alert
    }

    func dismiss(_ id: String) throws {
        _ = try get(id)
        store.dismiss(id)
    }

    func dismissAll() { store.dismissAll() }

    /// "Ask Ghost" on an alert. Fails for an alert that has no prompt.
    func ask(_ id: String) throws {
        guard let prompt = try get(id).ask else { throw APIError.invalid("this alert has nothing to ask about") }
        guard let askHandler else { throw APIError.unavailable("the chat is not available") }
        askHandler(prompt)
    }
}

#if canImport(Combine)

extension AlertsAPI: ObservableObject {
    nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
