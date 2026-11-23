import Foundation

/// What the Mac tells a phone after it took a message sent over the event socket.
package struct RemoteSendAck: Equatable, Sendable {
    package var clientID: String
    package var outcome: String
    /// The id of the user message in the chat. Nil when the message waits in the queue and has no item yet.
    package var itemID: String?
    /// The bus `seq` when the Mac took the message. The chat events up to it include the message.
    package var seq: Int

    package init(clientID: String, outcome: String, itemID: String?, seq: Int) {
        self.clientID = clientID
        self.outcome = outcome
        self.itemID = itemID
        self.seq = seq
    }
}

/// Remembers the messages a phone sent over the event socket, by the client id the phone made. A resend after a lost ack gets the first
/// ack back and creates nothing. A resend that arrives while the first is still running waits for it. A failed send is forgotten, so
/// its retry runs again.
@MainActor
package final class RemoteSendLedger {
    package static let capacity = 512

    private var tasks: [String: Task<RemoteSendAck, Error>] = [:]
    private var order: [String] = []

    package init() {}

    package func once(device: String, clientID: String, _ work: @escaping @MainActor () async throws -> RemoteSendAck) async throws -> RemoteSendAck {
        let key = device + "|" + clientID
        if let known = tasks[key] { return try await known.value }
        let task = Task { try await work() }
        tasks[key] = task
        order.append(key)
        if order.count > Self.capacity { tasks[order.removeFirst()] = nil }
        do { return try await task.value } catch {
            tasks[key] = nil
            order.removeAll { $0 == key }
            throw error
        }
    }
}
