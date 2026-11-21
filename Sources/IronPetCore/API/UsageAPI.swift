import Foundation

package struct UsageRequest: Codable, Equatable {
    package init(days: Int = 7, hourly: Bool = false) {
        self.days = days
        self.hourly = hourly
    }

    /// How many days to total, ending today.
    package var days = 7
    /// Cuts the buckets by hour. Only useful for one day.
    package var hourly = false
}

/// ironpet's own usage history: requests, tokens and cost per feature and model. It stays on this Mac.
@MainActor
package final class UsageAPI {
    private let store: UsageStore

    /// The running app's usage, for the Usage settings page. `IronPetAPI` sets it to its own.
    package static var live: UsageAPI?

    package init(store: UsageStore) { self.store = store }

    /// Why usage is only in memory, when the database could not be opened.
    package var unavailable: String? { store.unavailable }

    package func summary(_ request: UsageRequest = UsageRequest()) throws -> UsageSummary {
        guard (1...400).contains(request.days) else { throw APIError.invalid("days must be between 1 and 400") }
        return store.summary(days: request.days, hourly: request.hourly)
    }

    /// Records one request. Writes happen on a background queue.
    package func record(_ event: UsageEvent) { store.record(event) }
}
