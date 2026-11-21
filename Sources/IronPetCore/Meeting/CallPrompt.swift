import Foundation

/// Decides when Ghost offers to record a call. It never records: the user's click does.
@MainActor
package final class CallPrompt {
    package enum Action: Equatable {
        case offerRecord(String)
        case offerStop(String)
    }

    /// Meetings are on and "Offer to record calls" is on.
    package var isEnabled: () -> Bool
    /// A meeting is already being set up, recorded or wrapped up.
    package var isBusy: () -> Bool

    /// Apps whose current call the user declined. Cleared when the app releases the mic.
    package private(set) var snoozed: Set<String> = []
    /// The app whose call the user chose to record.
    package private(set) var recording: String?

    package init(isEnabled: @escaping () -> Bool, isBusy: @escaping () -> Bool) {
        self.isEnabled = isEnabled
        self.isBusy = isBusy
    }

    package func callStarted(_ app: String) -> Action? {
        guard isEnabled(), !isBusy(), !snoozed.contains(app) else { return nil }
        return .offerRecord(app)
    }

    package func callEnded(_ app: String) -> Action? {
        snoozed.remove(app)
        guard recording == app else { return nil }
        recording = nil
        return isBusy() ? .offerStop(app) : nil
    }

    package func notNow(_ app: String) { snoozed.insert(app) }

    package func accepted(_ app: String) { recording = app }
}
