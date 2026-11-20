import Foundation
#if canImport(Combine)
import Combine
#endif

/// Tells observers that something is about to change. Every store and facade in the API layer owns one and calls `send()`
/// from `willSet` where it used `@Published`, so a SwiftUI view sees the change before the value moves, as it did before.
///
/// Callbacks use `observe`, async consumers use `stream()`. On Apple platforms the signal also owns an
/// `ObservableObjectPublisher` and sends on it first, so an `ObservableObject` conformance can forward to it and
/// `@ObservedObject` keeps working. Everything else here is Foundation only.
///
/// A handler runs before the value changes. A handler that reads the store must hop to the next main-actor turn first.
@MainActor
final class ChangeSignal {
    /// The registered handlers and open streams. Lock-protected because a token is released, and a stream ends, on any thread.
    private let registry = Registry()

    #if canImport(Combine)
    /// What SwiftUI subscribes to through `ObservableObject`. `nonisolated` so the conformance can read it from outside the actor.
    nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()
    #endif

    init() {}

    deinit { registry.finishStreams() }

    /// Runs `handler` on the main actor each time the signal sends, until the returned token is cancelled or released.
    /// Keep the token: dropping it stops the handler.
    func observe(_ handler: @escaping @MainActor () -> Void) -> ChangeToken {
        let entry = Registry.Handler(handler)
        registry.add(entry)
        return ChangeToken(entry)
    }

    /// One element per `send()`. The stream finishes when the signal is deallocated or the consuming task is cancelled.
    func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(of: Void.self, bufferingPolicy: .unbounded)
        let key = registry.add(continuation)
        let registry = registry
        continuation.onTermination = { _ in registry.removeStream(key) }
        return stream
    }

    /// Announces a change that is about to happen. Handlers run in the order they registered, after the Combine publisher.
    func send() {
        #if canImport(Combine)
        objectWillChange.send()
        #endif
        for handler in registry.handlers() { handler.run() }
        for continuation in registry.streams() { continuation.yield() }
    }
}

/// Keeps one `observe` handler registered. Releasing or cancelling it stops the handler.
final class ChangeToken: @unchecked Sendable {
    private let handler: ChangeSignal.Registry.Handler

    fileprivate init(_ handler: ChangeSignal.Registry.Handler) { self.handler = handler }

    func cancel() { handler.cancel() }

    deinit { handler.cancel() }
}

extension ChangeSignal {
    final class Registry: @unchecked Sendable {
        final class Handler: @unchecked Sendable {
            private let lock = NSLock()
            private var body: (@MainActor () -> Void)?

            init(_ body: @escaping @MainActor () -> Void) { self.body = body }

            func cancel() {
                lock.lock()
                body = nil
                lock.unlock()
            }

            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return body == nil
            }

            /// Called only from `ChangeSignal.send`, which is on the main actor.
            @MainActor func run() {
                lock.lock()
                let body = body
                lock.unlock()
                body?()
            }
        }

        private let lock = NSLock()
        private var entries: [Handler] = []
        private var continuations: [Int: AsyncStream<Void>.Continuation] = [:]
        private var nextKey = 0

        func add(_ handler: Handler) {
            lock.lock()
            entries.removeAll { $0.isCancelled }
            entries.append(handler)
            lock.unlock()
        }

        func add(_ continuation: AsyncStream<Void>.Continuation) -> Int {
            lock.lock()
            defer { lock.unlock() }
            nextKey += 1
            continuations[nextKey] = continuation
            return nextKey
        }

        /// Live handlers, with the cancelled ones dropped.
        func handlers() -> [Handler] {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll { $0.isCancelled }
            return entries
        }

        func streams() -> [AsyncStream<Void>.Continuation] {
            lock.lock()
            defer { lock.unlock() }
            return Array(continuations.values)
        }

        func removeStream(_ key: Int) {
            lock.lock()
            continuations[key] = nil
            lock.unlock()
        }

        func finishStreams() {
            lock.lock()
            let open = continuations.values
            continuations = [:]
            entries = []
            lock.unlock()
            for continuation in open { continuation.finish() }
        }
    }
}
