import Foundation

/// Which install a host is and which agent its changes are attributed to. Both come from `NodeIdentity` and `AgentID`; `session.hello`
/// reports the same value.
package struct NodeInfo: Codable, Equatable {
    package init(id: String, agent: String) {
        self.id = id
        self.agent = agent
    }

    /// The node id, such as `node_9f3c1e5a07b2c4d8`. Made once per install and kept in `ironpet.db`.
    package var id: String
    /// The agent id every change is attributed to until the agent registry exists.
    package var agent: String
}

@MainActor
package final class NodeAPI {
    package let nodeID: String?
    package let agentID: AgentID

    package init(nodeID: String?, agentID: AgentID = .default) {
        self.nodeID = nodeID
        self.agentID = agentID
    }

    /// Nil when this host has no node id, as in a memory-only test host.
    package func info() -> NodeInfo? {
        nodeID.map { NodeInfo(id: $0, agent: agentID.rawValue) }
    }
}
