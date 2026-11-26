import Foundation

/// The id of agent 1, the agent every Mac has and the one a call without `agentId` addresses.
public let defaultAgentID = "agent_default"

/// One agent of the Mac, from `GET /v1/agent-records`. Only what the phone shows is decoded: the name, the pet, the agent CLI, the
/// model and whether the agent runs.
public struct RemoteAgentRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var name: String
    public var pet: String?
    public var agentCli: String
    public var model: String?
    /// False for an agent the Mac has turned off. A Mac from before several agents leaves it out, and that means true.
    public var enabled: Bool
    /// The paired device this agent runs on. Nil for an agent that runs on the Mac. A Mac from before phone agents leaves it out.
    public var deviceID: String?

    public init(id: String, number: Int = 1, name: String, pet: String? = nil, agentCli: String = "claude", model: String? = nil, enabled: Bool = true,
                deviceID: String? = nil) {
        self.id = id; self.number = number; self.name = name; self.pet = pet; self.agentCli = agentCli; self.model = model; self.enabled = enabled
        self.deviceID = deviceID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        pet = try c.decodeIfPresent(String.self, forKey: .pet)
        agentCli = try c.decodeIfPresent(String.self, forKey: .agentCli) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
    }

    enum CodingKeys: String, CodingKey { case id, number, name, pet, agentCli, model, enabled, deviceID = "deviceId" }

    /// True for an agent that runs on a phone. The phone lists it but never opens a Mac chat with it.
    public var runsOnPhone: Bool { deviceID != nil }

    /// Agent 1. The phone sends no `agentId` for it, which an older Mac also understands.
    public var isDefault: Bool { id == defaultAgentID }

    /// The `agentId` a chat call of this agent carries: nil for agent 1.
    public var chatAgentID: String? { isDefault ? nil : id }

    /// The name to show: the record's name, or "Agent 2" when the Mac sent none.
    public var displayName: String { name.isEmpty ? "Agent \(max(number, 1))" : name }
}

/// `GET /v1/agent-records`.
public struct AgentRecordListResponse: Codable, Equatable, Sendable {
    public var agents: [RemoteAgentRecord]
    public init(agents: [RemoteAgentRecord]) { self.agents = agents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = try c.decodeIfPresent(Lossy<RemoteAgentRecord>.self, forKey: .agents)?.elements ?? []
    }

    enum CodingKeys: String, CodingKey { case agents }
}
