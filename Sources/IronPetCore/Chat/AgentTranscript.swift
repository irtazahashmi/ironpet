import Foundation

/// Where an agent keeps the transcript of one session, and the only code that deletes such a file.
///
/// Claude Code appends every session to `~/.claude/projects/<slug of the cwd>/<sessionId>.jsonl`. Compaction changes what
/// the model sees, not the file, so the file only grows. Other agents are not covered: without a path IronPet can
/// prove, `file` returns nil and callers skip the session.
///
/// Deletion always names one file by session id. Nothing here lists or globs the projects folder.
package enum AgentTranscript {
    /// A variable so tests can point it at a temp folder.
    package nonisolated(unsafe) static var root = Paths.home.appendingPathComponent(".claude/projects")

    /// The agent whose transcript layout is known.
    package static let supportedAgent = "claude"

    /// The folder name Claude Code uses for a working directory: every character that is not a letter or digit becomes "-".
    package static func slug(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            let isAlphanumeric = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
            return isAlphanumeric ? Character(scalar) : "-"
        })
    }

    /// Session ids are UUIDs. Anything else could climb out of the project folder, so it gets no path.
    private static func isSafe(_ session: String) -> Bool {
        !session.isEmpty && session.count <= 128
            && session.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    /// The transcript file of `session`, or nil when the agent is not Claude Code, the id is unsafe or no such file exists.
    /// Claude Code names the folder after the real path of the cwd, so a symlinked cwd (`/tmp`) is tried both ways.
    package static func file(agent: String, workspace: String, session: String) -> URL? {
        guard agent == supportedAgent, isSafe(session) else { return nil }
        let real = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path
        for cwd in [workspace, real] {
            let url = root.appendingPathComponent(slug(cwd)).appendingPathComponent("\(session).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The file's size in bytes, or nil when it cannot be located.
    package static func size(agent: String, workspace: String, session: String) -> Int64? {
        guard let url = file(agent: agent, workspace: workspace, session: session),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Deletes the transcript of this one session. Returns true when a file was removed.
    @discardableResult
    package static func delete(agent: String, workspace: String, session: String) -> Bool {
        guard let url = file(agent: agent, workspace: workspace, session: session) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Deletes the transcripts of sessions that threads left at a rollover, once the file was last written more than
    /// `days` ago. Only ids from thread metadata are looked at, and any id that a thread (or the open chat) still runs on
    /// is skipped. Returns the ids whose file was deleted.
    @discardableResult
    package static func prunePrevious(threads: [ChatThread], days: Int, now: Date = Date(), alsoActive: Set<String> = []) -> [String] {
        var active = alsoActive
        for thread in threads { if let id = thread.activeSession { active.insert(id) } }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var removed: [String] = []
        for thread in threads {
            for id in thread.previousSessions ?? [] where !active.contains(id) {
                guard let url = file(agent: thread.agent, workspace: thread.workspace, session: id),
                      let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      modified < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(id) }
            }
        }
        return removed
    }

    /// `prunePrevious` over every saved thread with the configured retention, off the main thread.
    package static func pruneInBackground(alsoActive: Set<String> = []) {
        let days = Config.load().config.chat.sessionRetentionDays
        Task.detached(priority: .utility) {
            let removed = prunePrevious(threads: ThreadStore.all(), days: days, alsoActive: alsoActive)
            if !removed.isEmpty { ChatLog.note("deleted \(removed.count) old agent session transcript(s): \(removed.joined(separator: ", "))") }
        }
    }
}
