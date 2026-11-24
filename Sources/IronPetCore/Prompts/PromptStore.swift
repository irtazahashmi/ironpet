import Foundation

/// The files behind `Prompts`. `<id>.md` in `~/.ironpet/prompts/` is the text in use. `.defaults/<id>.md` is the default that
/// file was last made from, so ironpet can tell the user's edit from a newer default. A file the user never edited follows
/// the default silently. An edited one keeps the user's text, and `state` says an update is waiting.
package enum PromptStore {
    /// `~/.ironpet/prompts`. Tests point it at a temp folder.
    nonisolated(unsafe) package static var directory = Paths.root.appendingPathComponent("prompts")

    /// The default text of each prompt. Tests replace it to simulate an update to a default.
    nonisolated(unsafe) package static var defaultText: (String) -> String? = { Prompts.defaultText($0) }

    /// Reads and writes from the app and from agent turns on other threads.
    private static let lock = NSLock()

    package enum State: Equatable {
        /// The text in use is the default.
        case standard
        /// The user changed the text. The default has not changed since.
        case edited
        /// The default changed after the user edited the text. The user's text is kept until they choose.
        case updated
    }

    /// The text in use. Creates the files on first use.
    package static func text(_ id: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return reconcile(id).text
    }

    package static func state(_ id: String) -> State {
        lock.lock()
        defer { lock.unlock() }
        return reconcile(id).state
    }

    /// The text the user has, and the new default, while `state` is `updated`. Nil otherwise.
    package static func pendingUpdate(_ id: String) -> (previous: String, current: String)? {
        lock.lock()
        defer { lock.unlock() }
        let result = reconcile(id)
        guard result.state == .updated else { return nil }
        return (result.base, result.defaultText)
    }

    /// Saves the user's text. The default it was made from stays the same, so the state becomes `edited` or `standard`.
    package static func save(_ id: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard Prompts.info(id) != nil else { return }
        _ = reconcile(id)
        write(text, to: file(id))
    }

    /// Restores the default. Also what "Use new default" does while an update waits.
    package static func reset(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let def = defaultText(id) else { return }
        write(def, to: file(id))
        write(def, to: baseFile(id))
    }

    /// Keeps the user's text and stops asking about the new default.
    package static func keepMine(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let def = defaultText(id) else { return }
        write(def, to: baseFile(id))
    }

    // MARK: Private. Callers hold `lock`.

    private static func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".md") }

    private static func baseFile(_ id: String) -> URL {
        directory.appendingPathComponent(".defaults").appendingPathComponent(id + ".md")
    }

    private static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Makes the files match the default where the user has not edited, and reports the state. A missing file is created
    /// from the default. A missing base is taken to be the default, so an unknown file is treated as the user's edit.
    private static func reconcile(_ id: String) -> (text: String, state: State, base: String, defaultText: String) {
        guard let def = defaultText(id) else { return ("", .standard, "", "") }
        guard let user = read(file(id)) else {
            write(def, to: file(id))
            write(def, to: baseFile(id))
            return (def, .standard, def, def)
        }
        guard let base = read(baseFile(id)) else {
            write(def, to: baseFile(id))
            return (user, user == def ? .standard : .edited, def, def)
        }
        if base == def {
            return (user, user == def ? .standard : .edited, base, def)
        }
        // The default changed since the file was made.
        if user == base || user == def {
            write(def, to: file(id))
            write(def, to: baseFile(id))
            return (def, .standard, def, def)
        }
        return (user, .updated, base, def)
    }
}
