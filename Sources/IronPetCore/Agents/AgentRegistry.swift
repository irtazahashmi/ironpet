import Foundation

/// One agent: the identity and settings that belong to it. Today there is one, agent 1, the chat agent. Its id stays `AgentID.default`
/// (`agent_default`), so every row that step 1 attributed to that id already points at it and no row is rewritten.
package struct AgentRecord: Codable, Equatable, Sendable {
    package init(id: String, number: Int, name: String, pet: String? = nil, agentCli: String, model: String? = nil,
                 cliModels: [String: String] = [:], instructions: String = "", permissions: [String: String] = [:],
                 enabled: Bool = true, deviceID: String? = nil, created: Date = Date(timeIntervalSince1970: 0),
                 updated: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.enabled = enabled
        self.deviceID = deviceID
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
    /// A disabled agent has no process and no pet. Its threads, sessions and automations stay on disk. Agent 1 is always enabled.
    package var enabled: Bool
    /// The id of the paired device this agent runs on, for an agent that runs on a phone. Nil for an agent that runs on this Mac. The Mac
    /// lists a phone agent but starts no process for it, shows no pet for it and offers no chat with it.
    package var deviceID: String?
    package var created: Date
    package var updated: Date

    /// True for an agent that runs on a paired phone.
    package var isRemote: Bool { deviceID != nil }

    private enum CodingKeys: String, CodingKey {
        case id, number, name, pet, agentCli, model, cliModels, instructions, permissions, enabled, deviceID = "deviceId", created, updated
    }

    /// `enabled` is new on the wire, so a record from an older node, which has none, is enabled.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        name = try c.decode(String.self, forKey: .name)
        pet = try c.decodeIfPresent(String.self, forKey: .pet)
        agentCli = try c.decode(String.self, forKey: .agentCli)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        cliModels = try c.decodeIfPresent([String: String].self, forKey: .cliModels) ?? [:]
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        permissions = try c.decodeIfPresent([String: String].self, forKey: .permissions) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date(timeIntervalSince1970: 0)
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date(timeIntervalSince1970: 0)
    }
}

/// A change to an agent. A nil field is left as it is. `model` and `pet` are double optionals so a caller can also clear them.
package struct AgentRecordPatch: Equatable {
    package init(name: String? = nil, pet: String?? = nil, agentCli: String? = nil, model: String?? = nil, instructions: String? = nil,
                 enabled: Bool? = nil) {
        self.enabled = enabled
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
    package var enabled: Bool?
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
    /// Fires before the active agent changes, including when a disable or a delete moves it back to agent 1.
    package let activeChanges = ChangeSignal()
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
        .init(571, "agents: an enabled flag and a number counter, so an agent can be switched off or deleted without losing its history", sql: """
            ALTER TABLE agents ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
            CREATE TABLE agent_counter(value INTEGER NOT NULL);
            INSERT INTO agent_counter(value) SELECT COALESCE(MAX(number), 1) FROM agents;
            """),
        .init(585, "agents: the pet the user selected last, which voice and speech follow", sql: """
            CREATE TABLE agent_active(id INTEGER PRIMARY KEY CHECK (id = 1), agent_id TEXT NOT NULL) WITHOUT ROWID;
            """),
        .init(600, "agents: the paired device an agent runs on, for the agent loop on the phone", sql: """
            ALTER TABLE agents ADD COLUMN device_id TEXT;
            """),
    ]

    private static let columns = "id, number, name, pet, agent_cli, model, cli_models, instructions, permissions, created, updated, enabled, device_id"

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

    /// The agent the user selected last: voice goes to its chat and only it speaks its replies aloud. It is agent 1 until another is
    /// selected, and again when the stored one is disabled, deleted or unknown.
    package var activeAgentID: String {
        let stored = (try? database.read { try $0.rows("SELECT agent_id FROM agent_active WHERE id = 1") })?.first?.first as? String
        guard let stored, let record = get(stored), record.enabled else { return Self.chatAgentID }
        return record.id
    }

    /// The agent the chat runs on.
    package var chatAgent: AgentRecord? { self.get(Self.chatAgentID) }

    private static func record(_ row: [Database.Value]) -> AgentRecord? {
        guard row.count == 13, let id = row[0] as? String, let number = row[1] as? Int64, let name = row[2] as? String,
              let cli = row[4] as? String else { return nil }
        func map(_ value: Database.Value) -> [String: String] {
            guard let text = value as? String, let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: String] else { return [:] }
            return object
        }
        return AgentRecord(id: id, number: Int(number), name: name, pet: row[3] as? String, agentCli: cli, model: row[5] as? String,
                           cliModels: map(row[6]), instructions: row[7] as? String ?? "", permissions: map(row[8]),
                           enabled: (row[11] as? Int64 ?? 1) != 0, deviceID: row[12] as? String,
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
        if let enabled = patch.enabled {
            guard enabled || record.id != Self.chatAgentID else { throw APIError.invalid("agent 1 cannot be disabled") }
            record.enabled = enabled
        }
        guard record != before else { return before }
        record.updated = now()
        changes.send()
        if before.enabled, !record.enabled { clearActive(if: record.id) }
        try database.write { db in
            try db.execute("""
                UPDATE agents SET name = ?, pet = ?, agent_cli = ?, model = ?, cli_models = ?, instructions = ?, permissions = ?, enabled = ?, updated = ?
                WHERE id = ?
                """, [record.name, record.pet, record.agentCli, record.model, Self.json(record.cliModels), record.instructions,
                      Self.json(record.permissions), Int64(record.enabled ? 1 : 0), record.updated.timeIntervalSince1970, record.id])
        }
        return record
    }

    /// Makes an agent the active one and keeps it across restarts. An unknown or disabled agent is `notFound` or `unavailable`.
    /// Selecting the agent that is already active writes and announces nothing.
    package func select(active id: String) throws {
        guard let record = get(id) else { throw APIError.notFound("no agent with id \"\(id)\"") }
        guard record.enabled else { throw APIError.unavailable("agent \"\(record.id)\" is disabled") }
        guard !record.isRemote else { throw APIError.unsupported("agent \"\(record.id)\" runs on a phone") }
        guard activeAgentID != record.id else { return }
        activeChanges.send()
        try database.write { try $0.execute("INSERT OR REPLACE INTO agent_active(id, agent_id) VALUES(1, ?)", [record.id]) }
    }

    /// Forgets the stored active agent when it is `id`, so agent 1 is active again and a later enable does not bring the choice back.
    private func clearActive(if id: String) {
        guard storedActiveID == id else { return }
        activeChanges.send()
        try? database.write { try $0.execute("DELETE FROM agent_active WHERE id = 1") }
    }

    private var storedActiveID: String? {
        (try? database.read { try $0.rows("SELECT agent_id FROM agent_active WHERE id = 1") })?.first?.first as? String
    }

    /// Adds an agent, enabled. Its number is the next one and is never reused, even after a delete. Its id is `agent_` and a random part.
    @discardableResult
    package func create(name: String, pet: String? = nil, agentCli: String, model: String? = nil, instructions: String = "") throws -> AgentRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw APIError.invalid("an agent needs a name") }
        guard AgentCatalog.agent(id: agentCli) != nil else { throw APIError.invalid("unknown agent CLI \"\(agentCli)\"") }
        let created = now()
        changes.send()
        return try database.write { db -> AgentRecord in
            let top = (try db.rows("SELECT MAX(number) FROM agents").first?.first as? Int64) ?? 0
            let counter = (try db.rows("SELECT MAX(value) FROM agent_counter").first?.first as? Int64) ?? 0
            let number = max(top, counter) + 1
            let id = "agent_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
            let record = AgentRecord(id: id, number: Int(number), name: name, pet: pet, agentCli: agentCli, model: model,
                                     cliModels: model.map { [agentCli: $0] } ?? [:], instructions: instructions, created: created, updated: created)
            try db.execute("""
                INSERT INTO agents(id, number, name, pet, agent_cli, model, cli_models, instructions, permissions, legacy_imported, created, updated, enabled)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, '{}', 1, ?, ?, 1)
                """, [record.id, number, record.name, record.pet, record.agentCli, record.model, Self.json(record.cliModels),
                      record.instructions, created.timeIntervalSince1970, created.timeIntervalSince1970])
            try db.execute("UPDATE agent_counter SET value = ?", [number])
            return record
        }
    }

    /// Removes an agent's record. Its threads, sessions and automations stay on disk under an id that no longer resolves, so nothing
    /// lists them. Agent 1 cannot be deleted.
    package func delete(_ id: String) throws {
        guard let record = get(id) else { throw APIError.notFound("no agent with id \"\(id)\"") }
        guard record.id != Self.chatAgentID else { throw APIError.invalid("agent 1 cannot be deleted") }
        changes.send()
        clearActive(if: record.id)
        try database.write { try $0.execute("DELETE FROM agents WHERE id = ?", [record.id]) }
    }

    /// The agents that should be running: the enabled ones, in number order.
    /// Agents that run on a phone are not among them: they run on the phone.
    package func enabledAgents() -> [AgentRecord] { list().filter { $0.enabled && !$0.isRemote } }

    // MARK: Agents on a paired phone

    /// Registers the agent loop of a paired phone, or renames and re-models the one it registered before. One record belongs to one
    /// device, so a phone that registers twice has one agent. `provider` is the API the phone calls (`anthropic` or `openai`). The record
    /// is enabled, has no pet and starts no process on this Mac.
    @discardableResult
    package func registerDevice(_ deviceID: String, name: String, provider: String, model: String?) throws -> AgentRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw APIError.invalid("an agent needs a name") }
        guard !deviceID.isEmpty else { throw APIError.invalid("a device agent needs a device id") }
        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        if var existing = list().first(where: { $0.deviceID == deviceID }) {
            guard existing.name != name || existing.agentCli != provider || existing.model != model else { return existing }
            changes.send()
            existing.name = name
            existing.agentCli = provider
            existing.model = model
            existing.updated = now()
            try database.write { db in
                try db.execute("UPDATE agents SET name = ?, agent_cli = ?, model = ?, updated = ? WHERE id = ?",
                               [name, provider, model, existing.updated.timeIntervalSince1970, existing.id])
            }
            return existing
        }
        let created = now()
        changes.send()
        return try database.write { db -> AgentRecord in
            let top = (try db.rows("SELECT MAX(number) FROM agents").first?.first as? Int64) ?? 0
            let counter = (try db.rows("SELECT MAX(value) FROM agent_counter").first?.first as? Int64) ?? 0
            let number = max(top, counter) + 1
            let id = "agent_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
            let record = AgentRecord(id: id, number: Int(number), name: name, agentCli: provider, model: model, deviceID: deviceID,
                                     created: created, updated: created)
            try db.execute("""
                INSERT INTO agents(id, number, name, pet, agent_cli, model, cli_models, instructions, permissions, legacy_imported, created, updated, enabled, device_id)
                VALUES(?, ?, ?, NULL, ?, ?, '{}', '', '{}', 1, ?, ?, 1, ?)
                """, [record.id, number, name, provider, model, created.timeIntervalSince1970, created.timeIntervalSince1970, deviceID])
            try db.execute("UPDATE agent_counter SET value = ?", [number])
            return record
        }
    }

    /// Removes the agents of devices that are no longer paired. `devices` are the ids that still are.
    package func prune(devices: Set<String>) {
        for record in list() where record.deviceID.map({ !devices.contains($0) }) == true {
            changes.send()
            clearActive(if: record.id)
            try? database.write { try $0.execute("DELETE FROM agents WHERE id = ?", [record.id]) }
        }
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
