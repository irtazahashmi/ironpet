import Foundation
#if canImport(Combine)
import Combine
#endif

/// Which notifications `NotificationsAPI.list` returns. Every field narrows the list; the default is the newest 200.
package struct ListNotificationsRequest: Codable, Equatable {
    package init(
        since: Date? = nil,
        until: Date? = nil,
        source: String? = nil,
        type: NotificationType? = nil,
        unreadOnly: Bool = false,
        limit: Int = 200
    ) {
        self.since = since
        self.until = until
        self.source = source
        self.type = type
        self.unreadOnly = unreadOnly
        self.limit = limit
    }

    package var since: Date?
    package var until: Date?
    package var source: String?
    package var type: NotificationType?
    package var unreadOnly = false
    package var limit = 200
}

/// The notifications that match, newest first, and how many are unread in all (not only among the matches).
package struct NotificationList: Codable, Equatable {
    package init(notifications: [NotificationItem], unread: Int) {
        self.notifications = notifications
        self.unread = unread
    }

    package var notifications: [NotificationItem]
    package var unread: Int
}

/// The notification history: every bubble ironpet showed, with its full text and links. Clients read it and set read state here.
/// Notifications are created by the owners that show a bubble (`Announcer`, `AutomationService`), not by a client.
@MainActor
package final class NotificationsAPI {
    /// Fires before anything this API reads changes.
    package let changes = ChangeSignal()
    private let store: NotificationStore
    private var forwarding: [ChangeToken] = []

    package init(store: NotificationStore) {
        self.store = store
        forwarding = [
            store.changes.observe { [weak self] in self?.changes.send() },
        ]
    }

    /// A history that holds nothing, for a view that is not shown yet.
    package static func empty() -> NotificationsAPI {
        NotificationsAPI(store: NotificationStore(database: Database.open(path: nil, migrations: NotificationStore.migrations).database))
    }

    package var unreadCount: Int { store.unreadCount }

    package func list(_ request: ListNotificationsRequest = ListNotificationsRequest()) -> NotificationList {
        let filter = NotificationStore.Filter(since: request.since, until: request.until, source: request.source, type: request.type,
                                              unreadOnly: request.unreadOnly, limit: request.limit)
        return NotificationList(notifications: store.list(filter), unread: store.unreadCount)
    }

    /// One notification with its full description and links.
    package func get(_ id: String) throws -> NotificationItem {
        guard let item = store.get(id) else { throw APIError.notFound("no notification with id \(id)") }
        return item
    }

    /// The sources that have notifications: automation ids, and `system`.
    package func sources() -> [String] { store.sources() }

    package func markRead(_ id: String) throws {
        guard store.get(id) != nil else { throw APIError.notFound("no notification with id \(id)") }
        store.markRead(id)
    }

    package func markAllRead() { store.markAllRead() }
}

#if canImport(Combine)

extension NotificationsAPI: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
