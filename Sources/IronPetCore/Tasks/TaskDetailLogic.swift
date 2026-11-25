import Foundation

/// Which task the Tasks section shows in full. Nil shows the list.
package typealias TaskNavigation = ListNavigation<String>

/// Suggestions and validation for the "+ Label" popover.
package enum TaskLabelEditing {
    /// Keys used on other tasks that match `text` (case-insensitive), prefix matches first, then alphabetical.
    /// A key the task already has, and an exact match, are left out.
    package static func keySuggestions(for text: String, others: [[String: String]], own: [String: String] = [:]) -> [String] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        let keys = Set(others.flatMap(\.keys)).subtracting(own.keys).filter { $0.lowercased() != query }
        let matching = query.isEmpty ? Array(keys) : keys.filter { $0.lowercased().contains(query) }
        return matching.sorted { a, b in
            let (pa, pb) = (a.lowercased().hasPrefix(query), b.lowercased().hasPrefix(query))
            return pa != pb ? pa : a < b
        }
    }

    /// Values other tasks use for `key`, matching `text`, alphabetical.
    package static func valueSuggestions(for text: String, key: String, others: [[String: String]]) -> [String] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        let values = Set(others.compactMap { $0[key] }).filter { $0.lowercased() != query }
        return values.filter { query.isEmpty || $0.lowercased().contains(query) }.sorted()
    }

    /// The cleaned pair, or the message the popover shows. Uses the same rules as the CLI and MCP.
    package static func validate(key: String, value: String) -> Result<(key: String, value: String), TaskError> {
        do {
            let cleanKey = try TaskValidator.labelKey(key)
            guard let cleanValue = try TaskValidator.labels([cleanKey: value])[cleanKey] else { throw TaskError(message: "label value is empty") }
            return .success((cleanKey, cleanValue))
        } catch {
            return .failure(error as? TaskError ?? TaskError(message: error.localizedDescription))
        }
    }

    /// Adds the label (overwriting the key). Returns nil on success or the message to show.
    @MainActor
    package static func add(key: String, value: String, to id: String, in tasks: TasksAPI) -> String? {
        switch validate(key: key, value: value) {
        case .failure(let error): return error.message
        case .success(let pair):
            do { _ = try tasks.update(UpdateTaskRequest(id: id, labels: [pair.key: pair.value])); return nil }
            catch { return (error as? APIError)?.message ?? (error as? TaskError)?.message ?? error.localizedDescription }
        }
    }
}

/// One row of the links list in the detail view.
package struct TaskLinkRow: Equatable {
    package init(link: TaskLink) {
        self.link = link
    }

    package let link: TaskLink
    package var symbol: String { link.symbol }

    /// The label, or a short form of the ref: the host of a URL, the last path component of a file, the ref itself otherwise.
    package var title: String {
        if let label = link.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty { return label }
        switch link.kind {
        case .url: return URL(string: link.ref)?.host ?? link.ref
        case .file: return (link.ref as NSString).lastPathComponent
        case .thread, .session: return String(link.ref.prefix(12))
        }
    }

    /// The link's address as stored, shown under its title.
    package var reference: String { link.ref }

    /// "repo #123" when the link is a GitHub pull request URL (github.com or an enterprise host), otherwise nil.
    package var pullRequestKey: String? {
        guard link.kind == .url, let url = URL(string: link.ref), let host = url.host?.lowercased(), host.contains("github") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", Int(parts[3]) != nil else { return nil }
        return "\(parts[1]) #\(parts[3])"
    }

    package enum Action: Equatable {
        case openURL(URL)
        case revealFile(URL)
        case openThread(String)
        case openSession(String)
        case none
    }

    /// What clicking the row does. Web links must be http(s) because the database is a file anyone can edit, and files are
    /// revealed rather than opened because an agent wrote the path.
    package var action: Action {
        switch link.kind {
        case .url:
            guard let url = URL(string: link.ref), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .none }
            return .openURL(url)
        case .file:
            return .revealFile(URL(fileURLWithPath: (link.ref as NSString).expandingTildeInPath))
        case .thread: return .openThread(link.ref)
        case .session: return .openSession(link.ref)
        }
    }
}

extension TaskItem {
    /// The area, trimmed, or nil when missing or blank. Tasks filed before the rename carry `project`, which still counts.
    package var areaLabel: String? {
        for key in ["area", "project"] {
            if let value = labels[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }
}

/// Edits the detail view makes, with the notes the history needs.
package enum TaskEdits {
    package static let closedByUser = "Marked done by the user."

    /// Changes the status. Done takes the user's closing note; with none, a fixed text. Other changes record which status they moved to.
    @MainActor @discardableResult
    package static func setStatus(_ status: TaskStatus, of id: String, in tasks: TasksAPI, note: String? = nil) throws -> TaskItem {
        let typed = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let text = status == .done ? (typed ?? closedByUser) : (typed ?? "Moved to \(status.title) by the user.")
        return try tasks.update(UpdateTaskRequest(id: id, status: status, note: text))
    }

    @MainActor @discardableResult
    package static func setDue(_ due: Date?, of id: String, in tasks: TasksAPI) throws -> TaskItem {
        try tasks.update(UpdateTaskRequest(id: id, due: due, clearDue: due == nil))
    }

    /// Sets the context label, or removes it with nil.
    @MainActor @discardableResult
    package static func setContext(_ context: TaskContext?, of id: String, in tasks: TasksAPI) throws -> TaskItem {
        guard let context else { return try tasks.update(UpdateTaskRequest(id: id, removeLabels: [TaskContext.key])) }
        return try tasks.update(UpdateTaskRequest(id: id, labels: [TaskContext.key: context.rawValue]))
    }

    /// A blank name clears it.
    @MainActor @discardableResult
    package static func setWaitingOn(_ name: String, of id: String, in tasks: TasksAPI) throws -> TaskItem {
        try tasks.update(UpdateTaskRequest(id: id, waitingOn: name.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @MainActor @discardableResult
    package static func setNotes(_ notes: String, of id: String, in tasks: TasksAPI) throws -> TaskItem {
        try tasks.update(UpdateTaskRequest(id: id, notes: notes))
    }

    @MainActor @discardableResult
    package static func setTitle(_ title: String, of id: String, in tasks: TasksAPI) throws -> TaskItem {
        try tasks.update(UpdateTaskRequest(id: id, title: title))
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
