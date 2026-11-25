import Foundation

/// The id of an agent. Until the agent registry exists, every write is attributed to `AgentID.default`, and the registry
/// migration turns that id into agent 1.
package struct AgentID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The one agent ironpet has today, the chat agent.
    package static let `default` = AgentID("agent_default")

    package var description: String { rawValue }
}

/// Who made a change: the install (node) and the agent on it. Stored beside every change to shared data. Rows written before
/// this existed have neither, so readers treat both columns as nullable.
package struct Provenance: Equatable, Sendable {
    package var nodeID: String?
    package var agentID: AgentID

    package init(nodeID: String?, agentID: AgentID = .default) {
        self.nodeID = nodeID
        self.agentID = agentID
    }

    /// The values for the `node_id` and `agent_id` columns, in that order.
    package var columns: [Database.Value] { [nodeID, agentID.rawValue] }

    /// The provenance of a write made now through `db`: this install's node id and `agent`. The node id is nil when the database
    /// has no `node_identity` table, as in a test that opens only one feature's migrations.
    package static func current(_ db: Database.Connection, agent: AgentID = .default) -> Provenance {
        Provenance(nodeID: NodeIdentity.nodeID(db), agentID: agent)
    }
}

/// The id of this install, made once and kept in `ironpet.db` (`node_identity`, a single row). The migration creates it, so a fresh
/// database and an upgraded one both have it from the first open, and it survives restarts because it is in the file.
package enum NodeIdentity {
    /// Numbered above every migration in the app (record refs' 551 and the provenance columns' 552 to 555 come before it).
    package static let migrations: [Database.Migration] = [
        .init(560, "node: a stable id for this install", sql: """
            CREATE TABLE node_identity(id INTEGER PRIMARY KEY CHECK (id = 1), node_id TEXT NOT NULL, created REAL NOT NULL) WITHOUT ROWID;
            INSERT INTO node_identity(id, node_id, created) VALUES(1, 'node_' || lower(hex(randomblob(8))), CAST(strftime('%s', 'now') AS REAL));
            """),
    ]

    /// The prefix of a node id.
    package static let prefix = "node_"

    /// This install's node id. Nil when the database has no `node_identity` table yet.
    package static func nodeID(_ db: Database.Connection) -> String? {
        (try? db.rows("SELECT node_id FROM node_identity WHERE id = 1"))?.first?.first as? String
    }

    /// This install's node id, read from `database`.
    package static func nodeID(in database: Database) -> String? {
        try? database.read { nodeID($0) }
    }
}
