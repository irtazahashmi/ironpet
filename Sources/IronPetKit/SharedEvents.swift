#if canImport(Darwin)
import Foundation

/// Anything that yields the event socket's signals. `EventConnection` is the real one.
public protocol EventSignalSource: Sendable {
    func signals() -> AsyncStream<EventSignal>
}

extension EventConnection: EventSignalSource, ChatSocket {}

/// One event socket for every screen. The Mac allows three sockets per device, and each tab model wants the stream, so they share this:
/// the first subscriber opens the socket, every later one gets the same signals, and the socket closes with the last.
public final class SharedEventSource: EventSignalSource, @unchecked Sendable {
    private let source: EventSignalSource
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<EventSignal>.Continuation] = [:]
    private var pump: Task<Void, Never>?
    /// Names the running pump, so a pump that was cancelled and finishes late does not clear the state of the one that replaced it.
    private var pumpID: UUID?

    public init(_ source: EventSignalSource) { self.source = source }

    public func signals() -> AsyncStream<EventSignal> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            let start = pump == nil
            if start {
                let pumpID = UUID()
                self.pumpID = pumpID
                pump = Task { await self.run(pumpID) }
            }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    private func run(_ id: UUID) async {
        for await signal in source.signals() {
            lock.lock()
            let targets = Array(subscribers.values)
            lock.unlock()
            for target in targets { target.yield(signal) }
        }
        lock.lock()
        guard pumpID == id else {
            lock.unlock()
            return
        }
        let targets = Array(subscribers.values)
        subscribers = [:]
        pump = nil
        pumpID = nil
        lock.unlock()
        for target in targets { target.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers[id] = nil
        let idle = subscribers.isEmpty
        let task = idle ? pump : nil
        if idle {
            pump = nil
            pumpID = nil
        }
        lock.unlock()
        task?.cancel()
    }
}
#endif
