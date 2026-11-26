import Foundation

/// GTD's higher horizons. An area of focus (horizon 2) is a part of life or work to keep up, such as Health or Sales. A goal
/// (horizon 3) is what the user wants to reach in the next year or two, measured by key results. Vision and purpose (horizons
/// 4 and 5) are memory notes, not rows here.
package struct TaskArea: Identifiable, Equatable, Codable {
    package let id: String
    package var title: String
    package var notes: String
    package var created: Date
    package var updated: Date
}

package struct TaskGoal: Identifiable, Equatable, Codable {
    package enum Status: String, CaseIterable, Codable {
        case active, achieved, dropped

        package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    package let id: String
    package var title: String
    /// Why it matters, in a sentence.
    package var why: String
    /// The area id it belongs to.
    package var area: String?
    package var status: Status
    package var due: Date?
    package var created: Date
    package var updated: Date
}

/// One measure of a goal, such as "Monthly revenue from 10k to 25k EUR".
package struct TaskKeyResult: Identifiable, Equatable, Codable {
    package let id: String
    package var goal: String
    package var metric: String
    package var start: Double
    package var target: Double
    package var current: Double
    package var unit: String?
    package var due: Date?
    /// Where the current value comes from, such as a dashboard URL or "asked in the weekly review".
    package var source: String?
    package var updated: Date

    /// How far from start to target, from 0 to 1. Works for targets below the start too (fewer bugs, lower weight).
    package var progress: Double {
        guard target != start else { return current == target ? 1 : 0 }
        return min(1, max(0, (current - start) / (target - start)))
    }
}

package enum TaskGoalValidator {
    package static let maxNotes = 2000

    package static func number(_ value: Any?, field: String) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, !number.isJSONBoolean, number.doubleValue.isFinite else { throw TaskError(message: "\(field) must be a number") }
        return number.doubleValue
    }

    package static func text(_ value: Any?, field: String, limit: Int = maxNotes) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw TaskError(message: "\(field) must be a string") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= limit else { throw TaskError(message: "\(field) is longer than \(limit) characters") }
        return text
    }

    package static func status(_ value: Any?) throws -> TaskGoal.Status? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String, let status = TaskGoal.Status(rawValue: raw) else {
            throw TaskError(message: "status must be one of \(TaskGoal.Status.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return status
    }
}

extension TaskStore {
    package nonisolated static let goalMigrations: [Database.Migration] = [
        .init(574, "tasks: areas, goals and key results", sql: """
            CREATE TABLE IF NOT EXISTS task_areas(id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT NOT NULL,
                                                  created REAL NOT NULL, updated REAL NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS task_goals(id TEXT PRIMARY KEY, title TEXT NOT NULL, why TEXT NOT NULL, area TEXT, status TEXT NOT NULL,
                                                  due REAL, created REAL NOT NULL, updated REAL NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS task_key_results(id TEXT PRIMARY KEY, goal TEXT NOT NULL, metric TEXT NOT NULL, start REAL NOT NULL,
                                                        target REAL NOT NULL, current REAL NOT NULL, unit TEXT, due REAL, source TEXT,
                                                        updated REAL NOT NULL) WITHOUT ROWID;
            """),
    ]

    package func area(_ id: String) -> TaskArea? { areas.first { $0.id == id } }
    package func goal(_ id: String) -> TaskGoal? { goals.first { $0.id == id } }
    package func keyResults(of goal: String) -> [TaskKeyResult] { keyResults.filter { $0.goal == goal } }

    /// The mean progress of the goal's key results, or nil when it has none.
    package func progress(of goal: String) -> Double? {
        let results = keyResults(of: goal)
        guard !results.isEmpty else { return nil }
        return results.map(\.progress).reduce(0, +) / Double(results.count)
    }

    /// The projects that serve the goal (`TaskProject.goal` holds its id).
    package func projects(serving goal: String) -> [TaskProject] { projects.filter { $0.goal == goal } }

    @discardableResult
    package func upsertArea(id: String?, title: String?, notes: String?) throws -> TaskArea {
        let time = now()
        var area: TaskArea
        if let id {
            guard let existing = self.area(id) else { throw TaskError(message: "no area with id \"\(id)\"; task_goals_list shows them") }
            area = existing
            if let title { area.title = try TaskProjectValidator.title(title) }
        } else {
            guard let title else { throw TaskError(message: "title is required for a new area") }
            let clean = try TaskProjectValidator.title(title)
            area = TaskArea(id: AutomationValidator.slug(clean, taken: Set(areas.map(\.id))), title: clean, notes: "", created: time, updated: time)
        }
        if let notes { area.notes = notes }
        area.updated = time
        let saved = area
        try database.write { db in
            try db.execute("INSERT OR REPLACE INTO task_areas(id, title, notes, created, updated) VALUES(?, ?, ?, ?, ?)",
                           [saved.id, saved.title, saved.notes, saved.created.timeIntervalSince1970, saved.updated.timeIntervalSince1970])
        }
        reload()
        return self.area(saved.id) ?? saved
    }

    @discardableResult
    package func upsertGoal(id: String?, title: String?, why: String?, area: String??, status: TaskGoal.Status?, due: Date??) throws -> TaskGoal {
        let time = now()
        var goal: TaskGoal
        if let id {
            guard let existing = self.goal(id) else { throw TaskError(message: "no goal with id \"\(id)\"; task_goals_list shows them") }
            goal = existing
            if let title { goal.title = try TaskProjectValidator.title(title) }
        } else {
            guard let title else { throw TaskError(message: "title is required for a new goal") }
            let clean = try TaskProjectValidator.title(title)
            goal = TaskGoal(id: AutomationValidator.slug(clean, taken: Set(goals.map(\.id))), title: clean, why: "", area: nil, status: .active,
                            due: nil, created: time, updated: time)
        }
        if let why { goal.why = why }
        if let area {
            if let id = area, self.area(id) == nil { throw TaskError(message: "no area with id \"\(id)\"") }
            goal.area = area
        }
        if let status { goal.status = status }
        if let due { goal.due = due }
        goal.updated = time
        let saved = goal
        try database.write { db in
            try db.execute("""
                INSERT OR REPLACE INTO task_goals(id, title, why, area, status, due, created, updated) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """, [saved.id, saved.title, saved.why, saved.area, saved.status.rawValue, saved.due?.timeIntervalSince1970,
                      saved.created.timeIntervalSince1970, saved.updated.timeIntervalSince1970])
        }
        reload()
        return self.goal(saved.id) ?? saved
    }

    /// Adds a key result to a goal, or changes the one with `id`. A new one needs metric, start and target; `current` starts at `start`.
    @discardableResult
    package func upsertKeyResult(id: String?, goal: String?, metric: String?, start: Double?, target: Double?, current: Double?,
                                 unit: String??, due: Date??, source: String??) throws -> TaskKeyResult {
        let time = now()
        var result: TaskKeyResult
        if let id {
            guard let existing = keyResults.first(where: { $0.id == id }) else { throw TaskError(message: "no key result with id \"\(id)\"") }
            if let goal, goal != existing.goal { throw TaskError(message: "a key result cannot move to another goal; create a new one") }
            result = existing
            if let metric { result.metric = try TaskProjectValidator.title(metric) }
            if let start { result.start = start }
            if let target { result.target = target }
        } else {
            guard let goal, self.goal(goal) != nil else { throw TaskError(message: "goal must name an existing goal") }
            guard let metric, let start, let target else { throw TaskError(message: "a new key result needs metric, start and target") }
            let clean = try TaskProjectValidator.title(metric)
            let newID = AutomationValidator.slug("\(goal) \(clean)", taken: Set(keyResults.map(\.id)))
            result = TaskKeyResult(id: newID, goal: goal, metric: clean, start: start, target: target, current: start, unit: nil, due: nil,
                                   source: nil, updated: time)
        }
        if let current { result.current = current }
        if let unit { result.unit = unit }
        if let due { result.due = due }
        if let source { result.source = source }
        result.updated = time
        let saved = result
        try database.write { db in
            try db.execute("""
                INSERT OR REPLACE INTO task_key_results(id, goal, metric, start, target, current, unit, due, source, updated)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [saved.id, saved.goal, saved.metric, saved.start, saved.target, saved.current, saved.unit,
                      saved.due?.timeIntervalSince1970, saved.source, saved.updated.timeIntervalSince1970])
        }
        reload()
        return keyResults.first { $0.id == saved.id } ?? saved
    }

    nonisolated static func readHorizons(_ db: Database.Connection) throws -> (areas: [TaskArea], goals: [TaskGoal], keyResults: [TaskKeyResult]) {
        func date(_ value: Any?) -> Date? { (value as? Double).map(Date.init(timeIntervalSince1970:)) }
        let areas = try db.rows("SELECT id, title, notes, created, updated FROM task_areas ORDER BY title, id").compactMap { row -> TaskArea? in
            guard let id = row[0] as? String, let title = row[1] as? String, let created = date(row[3]), let updated = date(row[4]) else { return nil }
            return TaskArea(id: id, title: title, notes: row[2] as? String ?? "", created: created, updated: updated)
        }
        let goals = try db.rows("SELECT id, title, why, area, status, due, created, updated FROM task_goals ORDER BY title, id").compactMap { row -> TaskGoal? in
            guard let id = row[0] as? String, let title = row[1] as? String, let status = (row[4] as? String).flatMap(TaskGoal.Status.init(rawValue:)),
                  let created = date(row[6]), let updated = date(row[7]) else { return nil }
            return TaskGoal(id: id, title: title, why: row[2] as? String ?? "", area: row[3] as? String, status: status, due: date(row[5]),
                            created: created, updated: updated)
        }
        let results = try db.rows("""
            SELECT id, goal, metric, start, target, current, unit, due, source, updated FROM task_key_results ORDER BY goal, metric, id
            """).compactMap { row -> TaskKeyResult? in
            guard let id = row[0] as? String, let goal = row[1] as? String, let metric = row[2] as? String, let start = row[3] as? Double,
                  let target = row[4] as? Double, let current = row[5] as? Double, let updated = date(row[9]) else { return nil }
            return TaskKeyResult(id: id, goal: goal, metric: metric, start: start, target: target, current: current, unit: row[6] as? String,
                                 due: date(row[7]), source: row[8] as? String, updated: updated)
        }
        return (areas, goals, results)
    }
}
