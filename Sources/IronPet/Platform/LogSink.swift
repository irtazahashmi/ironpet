import Foundation

/// Where log lines go. `Log` (Support/Log.swift) is the struct call sites hold; it writes through a sink when it has one.
/// The existing `Log` keeps its name, so the protocol is `LogSink`.
protocol LogSink: Sendable {
    var isSupported: Bool { get }
    func note(category: String, _ message: String)
}

extension LogSink {
    var isSupported: Bool { true }
}

/// One line per message on stderr, for platforms without `os.Logger`.
struct StderrLogSink: LogSink {
    var subsystem = "ironpet"

    func note(category: String, _ message: String) {
        FileHandle.standardError.write(Data("[\(subsystem):\(category)] \(message)\n".utf8))
    }
}

/// Drops every line and reports itself unsupported.
struct UnsupportedLogSink: LogSink {
    var isSupported: Bool { false }
    func note(category: String, _ message: String) {}
}
