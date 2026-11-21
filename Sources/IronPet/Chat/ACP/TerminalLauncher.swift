import Foundation

/// Opens Terminal.app with the command an agent's `terminal` sign-in method asks for.
@MainActor
enum TerminalLauncher {
    static func shellCommand(agent: ACPAgent, method: AuthMethod, spawner: ProcessSpawner) -> String? {
        guard let launch = try? ACPBackend.launch(for: agent, spawner: spawner) else { return nil }
        let base = agent.viaHelper ? launch.arguments : []
        let words = [launch.executable.path] + base + method.args
        let env = method.env.sorted { $0.key < $1.key }.map { "\($0.key)=\(quote($0.value))" }
        return (env + words.map(quote)).joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func open(agent: ACPAgent, method: AuthMethod, spawner: ProcessSpawner) {
        guard let command = shellCommand(agent: agent, method: method, spawner: spawner) else { return }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        DispatchQueue.global().async {
            _ = try? spawner.spawn(ProcessSpec(executable: "/usr/bin/osascript", arguments: ["-e", script], output: .null, error: .null))
        }
    }
}
