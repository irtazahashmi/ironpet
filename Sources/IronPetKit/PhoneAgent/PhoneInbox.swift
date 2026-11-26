import Foundation

/// An inbox item as the Mac lists it, with only what the agent reads.
public struct InboxEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    public var due: String?
    public var notes: String

    public init(id: String, title: String, due: String? = nil, notes: String = "") {
        self.id = id; self.title = title; self.due = due; self.notes = notes
    }
}

/// An item the phone's agent added and the Mac has not taken yet. `id` is made once, when the agent adds the item, and is sent with every
/// delivery, so the Mac adds the item once however many times it is sent. Nothing else about the phone is in it.
///
/// The queue is keyed by this id on purpose: a later device sync (issue #374) can take the same ids over without a second copy.
public struct QueuedInboxItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var due: String?
    public var url: String?
    public var queuedAt: Date
    /// Set when the Mac refused the item (for example a title it cannot store), so it stops waiting and the user can see why.
    public var failure: String?

    public init(id: String = "phone-" + UUID().uuidString.lowercased(), title: String, notes: String = "", due: String? = nil, url: String? = nil,
                queuedAt: Date = Date(), failure: String? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.due = due; self.url = url; self.queuedAt = queuedAt; self.failure = failure
    }
}

/// Where the queue lives between launches. The app keeps one file in its own storage, outside backups.
public protocol InboxQueueStoring: AnyObject, Sendable {
    func load() -> [QueuedInboxItem]
    func save(_ items: [QueuedInboxItem])
}

// @unchecked Sendable: every access to `items` holds `lock`.
public final class MemoryInboxQueueStore: InboxQueueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [QueuedInboxItem]
    public init(_ items: [QueuedInboxItem] = []) { self.items = items }
    public func load() -> [QueuedInboxItem] { lock.lock(); defer { lock.unlock() }; return items }
    public func save(_ items: [QueuedInboxItem]) { lock.lock(); self.items = items; lock.unlock() }
}

public enum InboxDeliveryError: Error, Equatable, Sendable {
    /// The Mac could not be reached. The item keeps waiting.
    case unreachable
    /// The Mac answered and refused the item. It does not wait any longer.
    case rejected(String)
}

/// What the phone's inbox needs from the Mac. The app implements it over the paired client.
public protocol InboxRemote: Sendable {
    func items() async throws -> [InboxEntry]
    /// Sends one queued item. Sending the same `id` again is safe: the Mac ignores an id it has seen.
    func deliver(_ item: QueuedInboxItem) async throws
    func markDone(id: String) async throws
    func remove(id: String, note: String?) async throws
}

public enum InboxAddOutcome: Equatable, Sendable {
    /// The Mac has the item.
    case delivered(QueuedInboxItem)
    /// The Mac is out of reach. The item waits on the phone and is sent when the Mac answers.
    case queued(QueuedInboxItem)
    /// The Mac answered and refused the item, with this reason. It does not wait.
    case rejected(QueuedInboxItem, reason: String)
}

/// The phone agent's inbox: items it adds wait in a queue until the Mac takes them, and everything else goes to the Mac. The agent never
/// writes the Mac's inbox any other way, and it has no copy of the Mac's items.
public actor PhoneInbox {
    private let store: any InboxQueueStoring
    private let remote: any InboxRemote
    private let now: @Sendable () -> Date
    private var queue: [QueuedInboxItem]

    public init(store: any InboxQueueStoring, remote: any InboxRemote, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.remote = remote
        self.now = now
        queue = store.load()
    }

    /// Items waiting for the Mac, oldest first, including ones the Mac refused.
    public var pending: [QueuedInboxItem] { queue }

    /// Queues the item, then tries to send it. The queue is written first, so an item is never lost when the app quits mid-send.
    public func add(title: String, notes: String = "", due: String? = nil, url: String? = nil) async -> InboxAddOutcome {
        let item = QueuedInboxItem(title: title, notes: notes, due: due, url: url, queuedAt: now())
        queue.append(item)
        store.save(queue)
        await flush()
        guard let left = queue.first(where: { $0.id == item.id }) else { return .delivered(item) }
        if let reason = left.failure { return .rejected(left, reason: reason) }
        return .queued(item)
    }

    /// Sends the waiting items in order. It stops at the first one the Mac cannot be reached for, and keeps a refused one with its reason.
    /// Returns how many the Mac took.
    @discardableResult
    public func flush() async -> Int {
        var taken = 0
        for item in queue where item.failure == nil {
            do {
                try await remote.deliver(item)
                queue.removeAll { $0.id == item.id }
                taken += 1
            } catch InboxDeliveryError.rejected(let reason) {
                if let index = queue.firstIndex(where: { $0.id == item.id }) { queue[index].failure = reason }
            } catch {
                break
            }
        }
        store.save(queue)
        return taken
    }

    /// Drops a refused item the user has seen.
    public func discard(_ id: String) {
        queue.removeAll { $0.id == id }
        store.save(queue)
    }

    /// The Mac's inbox. Throws when the Mac cannot be reached.
    public func items() async throws -> [InboxEntry] { try await remote.items() }

    public func done(_ id: String) async throws { try await remote.markDone(id: id) }

    public func remove(_ id: String, note: String?) async throws { try await remote.remove(id: id, note: note) }
}
