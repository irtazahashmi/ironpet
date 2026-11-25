import Foundation

/// Remembers the task changes a phone made, by the client id the phone made for each. A replay after a lost answer gets the first
/// answer back and changes nothing. A change that failed is forgotten, so its retry runs again. The ledger is in memory: it covers the
/// replays of one Mac launch, and the phone sends each change again only when it did not see the answer.
@MainActor
package final class RemoteTaskLedger {
    package static let capacity = 512

    private var answers: [String: [String: Any]] = [:]
    private var order: [String] = []

    package init() {}

    /// Runs `work` once for this device and client id. A second call with the same pair returns the first answer.
    package func once(device: String, clientID: String?, _ work: () throws -> [String: Any]) throws -> [String: Any] {
        guard let clientID else { return try work() }
        guard UUID(uuidString: clientID) != nil else { throw RemoteFailure.invalid("client_id must be a UUID") }
        let key = device + "|" + clientID
        if let known = answers[key] { return known }
        let answer = try work()
        answers[key] = answer
        order.append(key)
        if order.count > Self.capacity { answers[order.removeFirst()] = nil }
        return answer
    }
}
