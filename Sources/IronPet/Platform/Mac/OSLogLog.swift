import Foundation
import IronPetCore
import os

/// Writes to `os.Logger`, at the notice level and public, like `Log` always did.
struct OSLogLog: LogSink {
    let subsystem: String

    init(subsystem: String = "com.ironpet") { self.subsystem = subsystem }

    func note(category: String, _ message: String) {
        Logger(subsystem: subsystem, category: category).notice("\(message, privacy: .public)")
    }
}
