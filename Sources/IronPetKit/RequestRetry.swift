import Foundation

/// The one retry policy for reads. A read that fails because the Mac cannot be reached is tried again with a growing wait, and only
/// the last failure is reported. Screens never retry on their own.
public struct RetryPolicy: Sendable, Equatable {
    /// How many times a read runs in all, the first try included.
    public var attempts: Int
    /// The wait before the second try. Each later wait doubles, up to `maxDelay`.
    public var base: Duration
    public var maxDelay: Duration

    public init(attempts: Int = 3, base: Duration = .seconds(1), maxDelay: Duration = .seconds(8)) {
        self.attempts = max(1, attempts)
        self.base = base
        self.maxDelay = maxDelay
    }

    public static let standard = RetryPolicy()
    /// One try, for a read the person just asked for twice over, such as pull to refresh while the strip already shows.
    public static let once = RetryPolicy(attempts: 1)

    /// The wait after the given failed try (1 for the first).
    public func delay(afterAttempt attempt: Int) -> Duration {
        let steps = max(0, min(attempt - 1, 16))
        var wait = base
        for _ in 0..<steps where wait < maxDelay { wait = wait * 2 }
        return min(wait, maxDelay)
    }
}

public enum RequestRetry {
    /// Runs `call`, and runs it again after a failure that a later try can fix. Cancellation and answers from the Mac end the loop at once.
    public static func perform<T>(
        _ policy: RetryPolicy = .standard,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onRetry: (Int) -> Void = { _ in },
        retriesTimeouts: Bool = true,
        _ call: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do { return try await call() } catch {
                guard attempt < policy.attempts, isTransient(error), retriesTimeouts || !isTimeout(error), !Task.isCancelled else { throw error }
                onRetry(attempt)
                try await sleep(policy.delay(afterAttempt: attempt))
                attempt += 1
            }
        }
    }

    /// True when the request ran out of time. A big read that timed out makes the Mac build the same answer again, so a caller can skip the retry.
    public static func isTimeout(_ error: Error) -> Bool {
        if let client = error as? ClientError { return client == .timedOut }
        return (error as? URLError)?.code == .timedOut
    }

    /// True when the Mac was not reached, or a proxy in front of it answered for it. An answer from the Mac itself (4xx) is final.
    public static func isTransient(_ error: Error) -> Bool {
        if let client = error as? ClientError {
            switch client {
            case .transport, .timedOut: return true
            case .api(let status, _, _): return status == 502 || status == 503 || status == 504
            default: return false
            }
        }
        return error is URLError && (error as? URLError)?.code != .cancelled
    }
}

public extension ClientError {
    /// The request never got an answer from the Mac: no route, a refused connection or a timeout.
    var isUnreachable: Bool { RequestRetry.isTransient(self) }
}
