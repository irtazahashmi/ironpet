import Foundation

/// One agent from the ACP registry that ironpet can start.
package struct ACPAgent: Identifiable, Hashable {
    package init(id: String, name: String, command: String, args: [String], helper: Helper?) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.helper = helper
    }

    /// Claude Code, Codex and Pi have no ACP mode of their own. A bundled adapter speaks ACP and drives the user's CLI,
    /// which it finds through the environment variable `pathVariable`.
    package struct Helper: Hashable {
        package init(adapter: String, pathVariable: String) {
            self.adapter = adapter
            self.pathVariable = pathVariable
        }

        package let adapter: String
        package let pathVariable: String
    }

    package let id: String
    package let name: String
    /// The executable the user installed, looked up on the login-shell PATH.
    package let command: String
    package let args: [String]
    package let helper: Helper?

    package var viaHelper: Bool { helper != nil }
}

package enum AgentCatalog {
    package static let all: [ACPAgent] = snapshot

    package static func agent(id: String?) -> ACPAgent? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Agents whose executable exists. Native agents are not yet checked against `initialize`; see `ACPProbe`.
    package static func present(path: String = LoginShell.path) -> [ACPAgent] {
        all.filter { LoginShell.find($0.command, path: path) != nil }
    }
}

/// The PATH of the user's login shell. A Finder-launched app has a minimal PATH that misses Homebrew and nvm.
package enum LoginShell {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var resolved: String? // Read and written only while holding `condition`.
    nonisolated(unsafe) private static var resolving = false // Same: only while holding `condition`.

    /// The login-shell PATH once `prepare(spawner:)` has found it. Until `prepare` was called it is the app's PATH plus the usual
    /// folders, without running a shell. While `prepare` is still working, a read waits for it, as the first read always did.
    package static var path: String {
        condition.lock()
        defer { condition.unlock() }
        while resolving { condition.wait() }
        return resolved ?? resolve(spawner: nil)
    }

    /// Runs the user's login shell to read its PATH, in the background, and stores the result. Call it once at launch. Reads of
    /// `path` made meanwhile wait for it.
    package static func prepare(spawner: ProcessSpawner) {
        condition.lock()
        guard resolved == nil, !resolving else { return condition.unlock() }
        resolving = true
        condition.unlock()
        DispatchQueue.global().async {
            let value = resolve(spawner: spawner)
            condition.lock()
            resolved = value
            resolving = false
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The PATH of the user's login shell when `spawner` can run it, else the app's PATH and the usual folders.
    package static func resolve(spawner: ProcessSpawner?) -> String {
        if let forced = ProcessInfo.processInfo.environment["IRONPET_LOGIN_PATH"] { return forced }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "/usr/bin", "/bin"]
        var parts: [String] = []
        if let spawner, let output = run(shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", spawner: spawner) {
            parts = parse(output)
        }
        parts += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        parts += fallback
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The shell prints rc-file noise before and after; the markers pick out the PATH.
    package static func parse(_ output: String) -> [String] {
        guard let start = output.range(of: "__IRONPET_PATH_BEGIN__"), let end = output.range(of: "__IRONPET_PATH_END__"),
              start.upperBound <= end.lowerBound else { return [] }
        return output[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
    }

    private static func run(shell: String, spawner: ProcessSpawner) -> String? {
        let args = ["-ilc", #"printf '__IRONPET_PATH_BEGIN__%s__IRONPET_PATH_END__' "$PATH""#]
        guard let process = try? spawner.spawn(ProcessSpec(executable: shell, arguments: args, error: .null)) else { return nil }
        // A slow rc file must not stall the app: give the shell five seconds.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = process.output?.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    package static func find(_ name: String, path: String = LoginShell.path) -> URL? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil }
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The environment for agent processes: the user's own, with the login-shell PATH.
    package static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }
}
