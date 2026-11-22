import Foundation
import os

/// Debug-level timestamps for each hop a phone message takes through the Mac, so the delay can be measured per hop. A line has the hop name
/// and a wall-clock time in milliseconds, never message content. Read them with
/// `log stream --level debug --predicate 'subsystem == "com.ironpet" AND category == "send-latency"'`.
enum HopLog {
    private static let logger = Logger(subsystem: "com.ironpet", category: "send-latency")

    static func mark(_ hop: String) {
        logger.debug("hop=\(hop, privacy: .public) t=\(Int(Date().timeIntervalSince1970 * 1000), privacy: .public)")
    }
}
