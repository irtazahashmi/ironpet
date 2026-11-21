import Foundation

/// Where log lines go. `Log` (Support/Log.swift) is the struct call sites hold; it writes through a sink when it has one.
/// The existing `Log` keeps its name, so the protocol is `LogSink`.
package protocol LogSink: Sendable {
    var isSupported: Bool { get }
    func note(category: String, _ message: String)
}

extension LogSink {
    package var isSupported: Bool { true }
}

/// One line per message on stderr, for platforms without `os.Logger`.
package struct StderrLogSink: LogSink {
    package init(subsystem: String = "ironpet") {
        self.subsystem = subsystem
    }

    package var subsystem = "ironpet"

    package func note(category: String, _ message: String) {
        FileHandle.standardError.write(Data("[\(subsystem):\(category)] \(message)\n".utf8))
    }
}

/// Drops every line and reports itself unsupported.
package struct UnsupportedLogSink: LogSink {
    package init() {}

    package var isSupported: Bool { false }
    package func note(category: String, _ message: String) {}
}
