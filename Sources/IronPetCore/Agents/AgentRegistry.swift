import Foundation

/// One agent: the identity and settings that belong to it. Today there is one, agent 1, the chat agent. Its id stays `AgentID.default`
/// (`agent_default`), so every row that step 1 attributed to that id already points at it and no row is rewritten.
package struct AgentRecord: Codable, Equatable, Sendable {
    package init(id: String, number: Int, name: String, pet: String? = nil, agentCli: String, model: String? = nil,
                 cliModels: [String: String] = [:], instructions: String = "", permissions: [String: String] = [:],
                 created: Date = Date(timeIntervalSince1970: 0), updated: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.number = number
        self.name = name
        self.pet = pet
        self.agentCli = agentCli
        self.model = model
        self.cliModels = cliModels
        self.instructions = instructions
        self.permissions = permissions
        self.created = created
        self.updated = updated
    }

    /// The record id. Agent 1 is `agent_default`.
    package var id: String
    /// 1 for the first agent, then 2, 3 and so on. Never reused.
    package var number: Int
    /// The agent's name, shown where the pet's name was shown before. Settings → General edits it as the pet's name.
    package var name: String
    /// Path to the pet's sprite sheet. Nil uses the bundled Ghost.
    package var pet: String?
    /// The catalog id of the agent CLI the chat runs, such as `cursor` or `claude`.
    package var agentCli: String
    /// The model picked for `agentCli`. Nil uses that CLI's own default.
    package var model: String?
    /// The model last picked for each CLI, so switching CLI and back keeps each one's choice.
    package var cliModels: [String: String]
    /// Standing instructions for this agent. Empty today: no setting writes them before the agents UI exists.
    package var instructions: String
    /// Tool permissions this agent has been given, by tool rule such as `Bash` or `Bash(git status:*)`, each `allow` or `deny`. An
    /// automation run this agent owns follows them. Empty today: the chat still asks for each permission.
    package var permissions: [String: String]
    package var created: Date
    package var updated: Date
}

/// A change to an agent. A nil field is left as it is. `model` and `pet` are double optionals so a caller can also clear them.
package struct AgentRecordPatch: Equatable {
    package init(name: String? = nil, pet: String?? = nil, agentCli: String? = nil, model: String?? = nil, instructions: String? = nil) {
        self.name = name
        self.pet = pet
        self.agentCli = agentCli
        self.model = model
        self.instructions = instructions
    }

    package var name: String?
    package var pet: String??
    package var agentCli: String?
    package var model: String??
    package var instructions: String?
}

/// The `agents` table: every agent on this install, and the one the chat runs. Agents never open the database themselves; this is the
/// only reader and writer, and `AgentRecordsAPI` is the way clients reach it.
@MainActor
package final class AgentRegistry {
    /// The registry the running app uses, for code that has no way to be handed one (the automation runner picks its agent from it).
    /// `IronPetAPI` sets it when it is built over the app's own config, so tests that build their own API do not replace it.
    package static var live: AgentRegistry?

    /// Fires before anything this registry holds changes.
    package let changes = ChangeSignal()
    private let database: Database
    private let now: () -> Date

    /// The chat runs on this agent. Until agents can be added there is only this one.
    package static let chatAgentID = AgentID.default.rawValue

    package nonisolated static let migrations: [Database.Migration] = [
        .init(570, "agents: the chat agent becomes agent 1", sql: """
            CREATE TABLE agents(
                id TEXT PRIMARY KEY,
                number INTEGER NOT NULL UNIQUE,
                name TEXT NOT NULL,
                pet TEXT,
                agent_cli TEXT NOT NULL,
                model TEXT,
                cli_models TEXT NOT NULL DEFAULT '{}',
                instructions TEXT NOT NULL DEFAULT '',
                permissions TEXT NOT NULL DEFAULT '{}',
                legacy_imported INTEGER NOT NULL DEFAULT 0,
                created REAL NOT NULL,
                updated REAL NOT NULL
            ) WITHOUT ROWID;
            INSERT INTO agents(id, number, name, agent_cli, created, updated)
                VALUES('agent_default', 1, 'Ghost', 'cursor', CAST(strftime('%s', 'now') AS REAL), CAST(strftime('%s', 'now') AS REAL));
            """),
    ]

    private static let columns = "id, number, name, pet, agent_cli, model, cli_models, instructions, permissions, created, updated"

    package init(database: Database, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    // MARK: Reading

    package func list() -> [AgentRecord] {
        let rows = (try? database.read { try $0.rows("SELECT \(Self.columns) FROM agents ORDER BY number") }) ?? []
        return rows.compactMap(Self.record)
    }

    /// The agent with this id. An empty id and `agent_default` are agent 1, so a row written before agents existed, with no agent id
    /// or the step 1 default, still resolves.
    package func get(_ id: String) -> AgentRecord? {
        let id = id.isEmpty ? Self.chatAgentID : id
        let rows = (try? database.read { try $0.rows("SELECT \(Self.columns) FROM agents WHERE id = ?", [id]) }) ?? []
        return rows.first.flatMap(Self.record)
    }

    /// The agent the chat runs on.
    package var chatAgent: AgentRecord? { self.get(Self.chatAgentID) }

    private static func record(_ row: [Database.Value]) -> AgentRecord? {
        guard row.count == 11, let id = row[0] as? String, let number = row[1] as? Int64, let name = row[2] as? String,
              let cli = row[4] as? String else { return nil }
        func map(_ value: Database.Value) -> [String: String] {
            guard let text = value as? String, let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: String] else { return [:] }
            return object
        }
        return AgentRecord(id: id, number: Int(number), name: name, pet: row[3] as? String, agentCli: cli, model: row[5] as? String,
                           cliModels: map(row[6]), instructions: row[7] as? String ?? "", permissions: map(row[8]),
                           created: Date(timeIntervalSince1970: row[9] as? Double ?? 0), updated: Date(timeIntervalSince1970: row[10] as? Double ?? 0))
    }

    private static func json(_ map: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Writing

    /// Applies `patch` to an agent. Nothing is written, and nothing is announced, when the patch changes no field.
    @discardableResult
    package func update(_ id: String, _ patch: AgentRecordPatch) throws -> AgentRecord {
        guard var record = get(id) else { throw APIError.notFound("no agent with id \"\(id)\"") }
        let before = record
        if let name = patch.name { record.name = name }
        if let pet = patch.pet { record.pet = pet }
        if let cli = patch.agentCli {
            record.agentCli = cli
            // A CLI switch brings back the model last picked for that CLI, unless the same patch sets one.
            if patch.model == nil { record.model = record.cliModels[cli] }
        }
        if let model = patch.model {
            record.model = model
            if let model { record.cliModels[record.agentCli] = model } else { record.cliModels[record.agentCli] = nil }
        }
        if let instructions = patch.instructions { record.instructions = instructions }
        guard record != before else { return before }
        record.updated = now()
        changes.send()
        try database.write { db in
            try db.execute("""
                UPDATE agents SET name = ?, pet = ?, agent_cli = ?, model = ?, cli_models = ?, instructions = ?, permissions = ?, updated = ?
                WHERE id = ?
                """, [record.name, record.pet, record.agentCli, record.model, Self.json(record.cliModels), record.instructions,
                      Self.json(record.permissions), record.updated.timeIntervalSince1970, record.id])
        }
        return record
    }

    // MARK: Settings from before agents existed

    /// Copies the chat settings an older build kept in `UserDefaults` and `config.json` onto agent 1, once. The migration cannot read
    /// them, so the first launch on this version does it, and `legacy_imported` stops a later launch from copying again over what
    /// Settings has written since. On a fresh install there is nothing to copy and agent 1 keeps its defaults.
    package func adoptLegacySettings(defaults: UserDefaults = .standard, pet: Config.Pet) {
        let done = (try? database.read { try $0.rows("SELECT legacy_imported FROM agents WHERE id = ?", [Self.chatAgentID]) })?.first?.first as? Int64
        guard done == 0 else { return }
        let cli = ChatAgentPreference.resolveID(defaults: defaults)
        var models: [String: String] = [:]
        for agent in AgentCatalog.all {
            if let model = defaults.string(forKey: "chatModel.\(agent.id)"), !model.isEmpty { models[agent.id] = model }
        }
        changes.send()
        try? database.write { db in
            try db.execute("""
                UPDATE agents SET name = ?, pet = ?, agent_cli = ?, model = ?, cli_models = ?, legacy_imported = 1 WHERE id = ?
                """, [pet.name, pet.sprite, cli, models[cli], Self.json(models), Self.chatAgentID])
        }
    }
}
