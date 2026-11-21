import Foundation

/// A logger for one subsystem and category. Lines go to the sink the owner gave it, else to `Log.fallbackSink`, which writes to
/// stderr until the platform replaces it. The Mac app sets an `OSLogLog` at launch (Sources/IronPet/main.swift), so lines reach
/// Console.app. Messages are logged as public, so pass only text that is safe to read there.
package struct Log {
    package let subsystem: String
    package let category: String
    /// Where lines go when the owner has one.
    package var sink: LogSink?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedSink: LogSink = StderrLogSink()

    /// The sink for every log without its own. Set it once at launch, before the first line is written.
    package static var fallbackSink: LogSink {
        get { lock.lock(); defer { lock.unlock() }; return storedSink }
        set { lock.lock(); defer { lock.unlock() }; storedSink = newValue }
    }

    package init(subsystem: String, category: String, sink: LogSink? = nil) {
        self.subsystem = subsystem
        self.category = category
        self.sink = sink
    }

    /// Logs at the notice level.
    package func notice(_ message: String) {
        (sink ?? Self.fallbackSink).note(category: category, message)
    }

    /// Logs at the info level.
    package func info(_ message: String) {
        (sink ?? Self.fallbackSink).note(category: category, message)
    }
}
