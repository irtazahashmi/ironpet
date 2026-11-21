import Foundation
#if canImport(Combine)
import Combine
#endif

/// An open item that deserves a look: CI that failed, a review waiting on you, a production error. Automations create
/// them with `alert` actions. The alerts list shows them until they are dismissed or the automation resolves them,
/// and the most urgent one sets Ghost's mood and badge.
package struct Signal: Identifiable, Equatable, Codable {
    package init(
        id: String,
        title: String,
        subtitle: String,
        url: URL?,
        date: Date = Date(),
        label: String,
        symbol: String,
        mood: PetMood,
        ask: String? = nil,
        detail: String? = nil,
        links: [NotificationLink] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.date = date
        self.label = label
        self.symbol = symbol
        self.mood = mood
        self.ask = ask
        self.detail = detail
        self.links = links
    }

    package let id: String
    package let title: String
    package let subtitle: String
    /// nil for an alert with nothing to open.
    package let url: URL?
    package var date = Date()
    /// The line above the title, such as "CI failed".
    package var label: String
    package var symbol: String
    package var mood: PetMood
    /// Prompt for "Ask Ghost", so the chat can pick up from the alert.
    package var ask: String?
    /// The full text and links an `alert` action gave, kept with the notification that announces the alert.
    package var detail: String?
    package var links: [NotificationLink] = []
}

@MainActor
package final class SignalStore {
    package init() {}

    /// Fires before `signals` changes.
    package let changes = ChangeSignal()
    package private(set) var signals: [Signal] = [] {
        willSet { changes.send() }
        didSet { events?.publish(.alertsChanged) }
    }
    /// Where changes are published for API clients.
    package weak var events: APIEventBus?

    /// Called for signals that should notify (not for state found on the first run).
    package var onNew: ((Signal) -> Void)?

    /// Called when the user dismisses a signal (one at a time or all).
    package var onDismiss: ((String) -> Void)?

    /// Puts back alerts that were open when ironpet last quit. Quiet: no `onNew`.
    package func restore(_ restored: [Signal]) {
        for signal in restored { add(signal, notify: false) }
    }

    package func add(_ signal: Signal, notify: Bool) {
        // One assignment, so one `alerts.changed` event.
        var next = signals.filter { $0.id != signal.id }
        next.insert(signal, at: 0)
        if next.count > 50 { next.removeLast(next.count - 50) }
        signals = next
        if notify { onNew?(signal) }
    }

    package func dismiss(_ id: String) {
        signals.removeAll { $0.id == id }
        onDismiss?(id)
    }

    package func removeAll(where shouldRemove: (Signal) -> Bool) {
        signals.removeAll(where: shouldRemove)
    }

    package func dismissAll() {
        let ids = signals.map(\.id)
        signals = []
        ids.forEach { onDismiss?($0) }
    }

    /// Most urgent mood among open signals and how many share it.
    package var summary: (mood: PetMood, count: Int)? {
        let ranked: [PetMood] = [.done, .failed, .needsInput]
        guard let top = signals.map(\.mood).max(by: { ranked.firstIndex(of: $0)! < ranked.firstIndex(of: $1)! }) else { return nil }
        return (top, signals.filter { $0.mood == top }.count)
    }
}

extension SignalStore {
    /// Adds the unavailable-database alert, with a bubble, when the database is the in-memory stand-in.
    package func reportIfUnavailable(_ database: Database) {
        if let signal = DatabaseNotice.signal(for: database) { add(signal, notify: true) }
    }
}

#if canImport(Combine)

extension SignalStore: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
