import Foundation

/// What changed. A client that gets one of these reads the area again through the API. The event carries an id
/// only when one thing changed (an alert id), so every event stays small and has no private text in it.
package enum APIEventKind: String, Codable, CaseIterable {
    case suggestionsChanged = "suggestions.changed"
    case chatItem = "chat.item"
    case chatState = "chat.state"
    case agentsChanged = "agents.changed"
    case alertsChanged = "alerts.changed"
    case bubbleShown = "bubble.shown"
    case bubbleDismissed = "bubble.dismissed"
    case notificationsChanged = "notifications.changed"
    case automationsChanged = "automations.changed"
    /// An automation waits for the user to press Approve on the Mac. The event carries the automation id and no buttons.
    case automationNeedsApproval = "automation.needsApproval"
    case meetingsChanged = "meetings.changed"
    case settingsChanged = "settings.changed"
    case petMood = "pet.mood"
    case assetsChanged = "assets.changed"
}

package struct APIEvent: Codable, Equatable {
    package init(seq: Int, at: Date, kind: APIEventKind, id: String?, agentId: String? = nil) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.id = id
        self.agentId = agentId
    }

    /// Counts up from 1 for the life of the app. A client that reconnects passes the last `seq` it saw.
    package let seq: Int
    package let at: Date
    package let kind: APIEventKind
    /// The thing that changed, when it is one thing.
    package let id: String?
    /// The agent a chat event is about. Nil for agent 1 and for every event that is not about one agent's chat.
    package let agentId: String?
}

/// The one event stream. Stores publish into it, and clients subscribe to it. It keeps the last `capacity` events so a client
/// that was away can ask for what it missed.
@MainActor
package final class APIEventBus {
    /// Handle for one subscription. `cancel()` stops delivery.
    @MainActor
    package final class Subscription {
        fileprivate let token = UUID()
        private weak var bus: APIEventBus?
        /// True when the buffer no longer held every event after the `seq` the client gave. The client missed some
        /// and has to read the whole state again.
        package let gap: Bool

        fileprivate init(bus: APIEventBus, gap: Bool) {
            self.bus = bus
            self.gap = gap
        }

        package func cancel() { bus?.handlers[token] = nil }
    }

    /// Kinds whose events replace an earlier buffered event with the same id.
    private static let coalesces: Set<APIEventKind> = [.chatItem, .chatState]
    /// How far back the buffer looks for the event to replace.
    private static let coalesceWindow = 64

    package let capacity: Int
    /// Names this launch. `seq` restarts at 1 on every launch, so a client that kept a `seq` across launches sends this too, and a
    /// different value tells the host that the `seq` belongs to another numbering.
    package let epoch = UUID().uuidString
    package private(set) var lastSeq = 0
    /// Counts the chat events published in this launch. It never drops with the buffer, so two reads that see the same value saw the
    /// same chat. The remote API builds the chat ETag from it, so a repeat read costs no build.
    package private(set) var chatVersion = 0
    /// The highest `seq` pushed out of a full buffer. Events merged into a newer one do not count: nothing was lost.
    private var evictedThrough = 0
    private var buffer: [APIEvent] = []
    private var handlers: [UUID: (APIEvent) -> Void] = [:]
    private let now: () -> Date

    /// How many events a reconnecting client can miss and still replay. 4,000 covers more than an hour at the 46 events a minute a busy
    /// chat publishes, and an event is a few dozen bytes.
    package nonisolated static let defaultCapacity = 4000

    package init(capacity: Int = APIEventBus.defaultCapacity, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    package func publish(_ kind: APIEventKind, id: String? = nil, agentId: String? = nil) {
        lastSeq += 1
        if kind == .chatItem || kind == .chatState { chatVersion += 1 }
        let event = APIEvent(seq: lastSeq, at: now(), kind: kind, id: id, agentId: agentId)
        // Streamed text changes one message hundreds of times. A client only needs to know that it changed since it last looked, so
        // the buffer keeps the newest event for each message (and for each part of the chat state) instead of every one.
        // Live subscribers still get every event. Without this a few seconds of streaming would push every other event out.
        if Self.coalesces.contains(kind), let id,
           let earlier = buffer[max(0, buffer.count - Self.coalesceWindow)...].lastIndex(where: { $0.kind == kind && $0.id == id && $0.agentId == agentId }) {
            buffer.remove(at: earlier)
        }
        buffer.append(event)
        if buffer.count > capacity {
            evictedThrough = max(evictedThrough, buffer[buffer.count - capacity - 1].seq)
            buffer.removeFirst(buffer.count - capacity)
        }
        for handler in Array(handlers.values) { handler(event) }
    }

    /// The events with a `seq` above `seq`, oldest first, and whether older ones were already dropped.
    package func replay(after seq: Int) -> (events: [APIEvent], gap: Bool) {
        let missed = buffer.filter { $0.seq > seq }
        // A `seq` above `lastSeq` comes from an earlier launch, whose numbers restarted: the client must re-read everything.
        return (missed, seq < evictedThrough || seq > lastSeq)
    }

    /// Calls `handler` with every later event. With `after`, it first gets the buffered events above that `seq`, in order, before
    /// any new one, so a reconnecting client sees no hole and no repeat.
    @discardableResult
    package func subscribe(after seq: Int? = nil, _ handler: @escaping (APIEvent) -> Void) -> Subscription {
        var gap = false
        if let seq {
            let missed = replay(after: seq)
            gap = missed.gap
            missed.events.forEach(handler)
        }
        let subscription = Subscription(bus: self, gap: gap)
        handlers[subscription.token] = handler
        return subscription
    }
}
