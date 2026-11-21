import Foundation

/// One line per event that clears the chat, opens a thread, changes the folder or agent, or restarts the agent process.
/// Read it with `log show --predicate 'subsystem == "com.ironpet" AND category == "chat"'`.
package enum ChatLog {
    package static let log = Log(subsystem: "com.ironpet", category: "chat")
    /// Receives every message. Tests set it to check what was logged.
    package nonisolated(unsafe) static var sink: ((String) -> Void)?

    package static func note(_ message: String) {
        log.notice(message)
        sink?(message)
    }
}
