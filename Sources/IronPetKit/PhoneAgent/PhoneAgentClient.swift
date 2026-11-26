import Foundation

extension IronPetClient {
    /// Sends one item the phone's agent queued. The Mac adds an id it has not seen and ignores one it has, so this is safe to send again.
    /// A Mac that is out of reach or too old for the route is `unreachable` and the item keeps waiting. A Mac that refuses the item with
    /// a 4xx other than a missing route gives its reason.
    public func deliver(_ item: QueuedInboxItem) async throws {
        var json: [String: Any] = ["id": item.id, "title": item.title, "notes": item.notes]
        if let due = item.due { json["due"] = due }
        if let url = item.url { json["url"] = url }
        do {
            try await post(APIPath.suggestions, json: json)
        } catch ClientError.api(let status, _, let message) where (400..<500).contains(status) && status != 404 && status != 405 && status != 429 {
            throw InboxDeliveryError.rejected(message)
        } catch ClientError.unauthorized {
            throw ClientError.unauthorized
        } catch {
            throw InboxDeliveryError.unreachable
        }
    }

    /// Registers this phone's agent with the Mac, or updates the one it registered. Needs a Mac that has phone agents.
    @discardableResult
    public func registerPhoneAgent(name: String, provider: AgentProvider, model: String) async throws -> RemoteAgentRecord {
        let json: [String: Any] = ["name": name, "provider": provider.rawValue, "model": model]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try decode(RemoteAgentRecord.self, from: try await perform(request("PUT", APIPath.deviceAgent, body: data)))
    }
}

/// The Mac's inbox for the phone agent, over the paired client.
public struct ClientInboxRemote: InboxRemote {
    private let client: IronPetClient

    public init(_ client: IronPetClient) { self.client = client }

    public func items() async throws -> [InboxEntry] {
        try await client.suggestions().map { InboxEntry(id: $0.id, title: $0.title, due: $0.due, notes: $0.notes) }
    }

    public func deliver(_ item: QueuedInboxItem) async throws { try await client.deliver(item) }

    public func markDone(id: String) async throws { try await client.acceptSuggestion(id: id) }

    public func remove(id: String, note: String?) async throws { try await client.rejectSuggestion(id: id) }
}

/// The Mac's memory for the phone agent, as text the model can read.
public struct ClientMemoryHost: PhoneMemoryHost {
    private let client: IronPetClient

    public init(_ client: IronPetClient) { self.client = client }

    public func search(_ query: String) async throws -> String {
        let list = try await client.memory(filter: .all, query: query)
        guard !list.pages.isEmpty else { return "No memory page matches \"\(query)\"." }
        return list.pages.prefix(10).map { "- \($0.id) (\($0.typeLabel)): \($0.name). \($0.summary)" }.joined(separator: "\n")
    }

    public func page(_ id: String) async throws -> String {
        let page = try await client.memoryPage(id: id)
        var lines = ["\(page.title) (\(page.typeLabel))"]
        if !page.aliases.isEmpty { lines.append("Also called: " + page.aliases.joined(separator: ", ")) }
        lines += page.facts.prefix(30).map { "- " + ($0.date.isEmpty ? "" : "\($0.date): ") + $0.text }
        return lines.joined(separator: "\n")
    }
}
