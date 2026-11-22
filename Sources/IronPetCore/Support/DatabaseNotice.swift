import Foundation
import enum IronPetKit.SharedSymbols

/// What the user sees when `ironpet.db` could not be opened and ironpet runs on an in-memory stand-in.
package enum DatabaseNotice {
    package static let alertID = "database-unavailable"
    package static let bannerText = "Not saved: the database is unavailable"

    /// The alert for an unavailable database, or nil for a normal one.
    package static func signal(for database: Database) -> Signal? {
        guard let reason = database.unavailableReason else { return nil }
        let path = database.unavailablePath?.path ?? "ironpet.db"
        return Signal(id: alertID, title: "\(reason)\nFile: \(path)", subtitle: path, url: nil,
                      label: "ironpet can't open its database", symbol: SharedSymbols.warning, mood: .failed, ask: nil)
    }

    /// The error that tasks tools and the CLI return instead of an empty list.
    package static func toolError(_ reason: String) -> String { "\(bannerText). \(reason)" }
}
