import Foundation

/// A GTD project: an outcome that takes more than one step, such as "Launch the new site". Its tasks are the steps. Not the
/// memory's projects, which are folders and repositories (`projects_resolve`).
package struct TaskProject: Identifiable, Equatable, Codable {
    package enum Status: String, CaseIterable, Codable {
        case active, someday, done

        package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    package init(id: String, title: String, outcome: String = "", area: String? = nil, goal: String? = nil, status: Status = .active,
                 reviewDays: Int? = nil, reviewed: Date? = nil, created: Date, updated: Date) {
        self.id = id
        self.title = title
        self.outcome = outcome
        self.area = area
        self.goal = goal
        self.status = status
        self.reviewDays = reviewDays
        self.reviewed = reviewed
        self.created = created
        self.updated = updated
    }

    package let id: String
    package var title: String
    /// What done looks like, in one sentence.
    package var outcome: String
    package var area: String?
    /// The goal it serves. Free text until goals have their own table.
    package var goal: String?
    package var status: Status
    /// Look at it again every this many days. Nil: only in the weekly review.
    package var reviewDays: Int?
    package var reviewed: Date?
    package var created: Date
    package var updated: Date

    /// An active project whose review interval has passed since it was last reviewed (or created).
    package func isDueForReview(now: Date) -> Bool {
        guard status == .active, let reviewDays else { return false }
        return (reviewed ?? created).addingTimeInterval(TimeInterval(reviewDays) * 86_400) <= now
    }
}

package enum TaskProjectValidator {
    package static let maxTitle = 120
    package static let maxOutcome = 500
    package static let maxReviewDays = 365

    package static func title(_ value: Any?) throws -> String {
        guard let raw = value as? String else { throw TaskError(message: "title must be a string") }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !title.isEmpty else { throw TaskError(message: "title is empty") }
        guard title.count <= maxTitle else { throw TaskError(message: "title is longer than \(maxTitle) characters") }
        return title
    }

    package static func outcome(_ value: Any?) throws -> String {
        guard let value, !(value is NSNull) else { return "" }
        guard let raw = value as? String else { throw TaskError(message: "outcome must be a string") }
        let outcome = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard outcome.count <= maxOutcome else { throw TaskError(message: "outcome is longer than \(maxOutcome) characters") }
        return outcome
    }

    /// An area or goal: one line, like a label value. Blank clears it.
    package static func line(_ value: Any?, field: String) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw TaskError(message: "\(field) must be a string") }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard !line.contains("\n"), line.count <= TaskValidator.maxLabelValue else {
            throw TaskError(message: "\(field) must be one line of at most \(TaskValidator.maxLabelValue) characters")
        }
        return line
    }

    package static func status(_ value: Any?) throws -> TaskProject.Status? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String, let status = TaskProject.Status(rawValue: raw) else {
            throw TaskError(message: "status must be one of \(TaskProject.Status.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return status
    }

    package static func reviewDays(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let days = value as? Int, (1...maxReviewDays).contains(days) else {
            throw TaskError(message: "review_days must be a whole number from 1 to \(maxReviewDays)")
        }
        return days
    }
}

extension TaskStore {
    package nonisolated static let projectMigrations: [Database.Migration] = [
        // GTD projects, and the link from a task to its project. Separate from the memory's projects.
        .init(572, "tasks: projects") { db in
            try db.execute("""
                CREATE TABLE IF NOT EXISTS task_projects(id TEXT PRIMARY KEY, title TEXT NOT NULL, outcome TEXT NOT NULL, area TEXT, goal TEXT,
                                                         status TEXT NOT NULL, review_days INTEGER, reviewed REAL,
                                                         created REAL NOT NULL, updated REAL NOT NULL) WITHOUT ROWID
                """)
            if !(try TaskStore.columns(db, "task_items")).contains("project") {
                try db.execute("ALTER TABLE task_items ADD COLUMN project TEXT")
            }
        },
    ]

    package func project(_ id: String) -> TaskProject? { projects.first { $0.id == id } }

    /// The steps the user can take now: open tasks of the project that nobody else holds and that are not deferred.
    package func nextActions(of project: String, now: Date) -> [TaskItem] {
        ordered.filter { task in
            task.project == project && [.backlog, .inProgress, .needsYou].contains(task.status) && task.waitingOn == nil
                && !task.isDeferred(now: now)
        }
    }

    /// Active projects with no next action. GTD keeps every active project moving, so the task review proposes one for each.
    package func stalledProjects(now: Date) -> [TaskProject] {
        projects.filter { $0.status == .active && nextActions(of: $0.id, now: now).isEmpty }
    }

    /// Adds a project, or changes the one with `id`. Nil fields keep the project's value; `area` and `goal` blank clear them.
    @discardableResult
    package func upsertProject(id: String?, title: String?, outcome: String?, area: String??, goal: String??, status: TaskProject.Status?,
                               reviewDays: Int??, markReviewed: Bool = false) throws -> TaskProject {
        let time = now()
        var project: TaskProject
        if let id, let existing = self.project(id) {
            project = existing
            if let title { project.title = try TaskProjectValidator.title(title) }
        } else {
            guard let title else { throw TaskError(message: "title is required for a new project") }
            let clean = try TaskProjectValidator.title(title)
            let newID = id ?? AutomationValidator.slug(clean, taken: Set(projects.map(\.id)))
            guard id.map({ !$0.isEmpty && $0.count <= 60 && !$0.contains(" ") }) ?? true else { throw TaskError(message: "id must be a slug") }
            project = TaskProject(id: newID, title: clean, created: time, updated: time)
        }
        if let outcome { project.outcome = try TaskProjectValidator.outcome(outcome) }
        if let area { project.area = try TaskProjectValidator.line(area, field: "area") }
        if let goal { project.goal = try TaskProjectValidator.line(goal, field: "goal") }
        if let status { project.status = status }
        if let reviewDays { project.reviewDays = reviewDays }
        if markReviewed { project.reviewed = time }
        project.updated = time
        let saved = project
        try database.write { db in
            try db.execute("""
                INSERT OR REPLACE INTO task_projects(id, title, outcome, area, goal, status, review_days, reviewed, created, updated)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [saved.id, saved.title, saved.outcome, saved.area, saved.goal, saved.status.rawValue, saved.reviewDays,
                      saved.reviewed?.timeIntervalSince1970, saved.created.timeIntervalSince1970, saved.updated.timeIntervalSince1970])
        }
        reload()
        didChange(nil)
        return self.project(saved.id) ?? saved
    }

    nonisolated static func readProjects(_ db: Database.Connection) throws -> [TaskProject] {
        try db.rows("SELECT id, title, outcome, area, goal, status, review_days, reviewed, created, updated FROM task_projects ORDER BY title, id")
            .compactMap { row in
                guard let id = row[0] as? String, let title = row[1] as? String,
                      let status = (row[5] as? String).flatMap(TaskProject.Status.init(rawValue:)),
                      let created = row[8] as? Double, let updated = row[9] as? Double else { return nil }
                return TaskProject(id: id, title: title, outcome: row[2] as? String ?? "", area: row[3] as? String, goal: row[4] as? String,
                                   status: status, reviewDays: (row[6] as? Int64).map(Int.init),
                                   reviewed: (row[7] as? Double).map(Date.init(timeIntervalSince1970:)),
                                   created: Date(timeIntervalSince1970: created), updated: Date(timeIntervalSince1970: updated))
            }
    }
}
