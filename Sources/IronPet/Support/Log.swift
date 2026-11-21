import Foundation
#if canImport(os)
import os
#endif

/// A logger for one subsystem and category. Writes to `os.Logger` where the `os` module exists and to stderr elsewhere.
/// Messages are logged as public, so pass only text that is safe to read in Console.app.
struct Log {
    let subsystem: String
    let category: String
    /// Where lines go when the owner has one. Without it the log writes to `os.Logger` or stderr itself, as before.
    var sink: LogSink?

    #if canImport(os)
    private let logger: Logger
    #endif

    init(subsystem: String, category: String, sink: LogSink? = nil) {
        self.subsystem = subsystem
        self.category = category
        self.sink = sink
        #if canImport(os)
        logger = Logger(subsystem: subsystem, category: category)
        #endif
    }

    /// Logs at the notice level.
    func notice(_ message: String) {
        if let sink { return sink.note(category: category, message) }
        #if canImport(os)
        logger.notice("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(subsystem):\(category)] \(message)\n".utf8))
        #endif
    }

    /// Logs at the info level.
    func info(_ message: String) {
        if let sink { return sink.note(category: category, message) }
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(subsystem):\(category)] \(message)\n".utf8))
        #endif
    }
}
