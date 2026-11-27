import Foundation

/// What the app binary does with its command-line arguments. The GUI starts only for no arguments or for options, never for a
/// bare word. A subcommand the binary does not know, such as the removed `tasks`, must fail instead of opening a second pet,
/// because automations and agents run the binary with subcommands.
package enum LaunchArguments {
    package enum Route: Equatable {
        case gui
        /// Print `message` to standard error and exit with a non-zero status. No window opens.
        case reject(String)
    }

    /// Options the GUI accepts. A single dash is a macOS defaults override (`-chatDraft ""`, `-psn_0_123`) and is always allowed.
    package static let guiOptions: Set<String> = ["--test-mode", "--render-previews"]

    /// `arguments` is `CommandLine.arguments`, so the first element is the program path. The subcommands that run before this
    /// check (`automations`, `inbox`, `mcp` and the others) never reach it.
    package static func route(_ arguments: [String]) -> Route {
        guard let first = arguments.dropFirst().first else { return .gui }
        if first == "tasks" {
            return .reject("ironpet: the tasks command was removed. The Inbox replaced the task list, so use `ironpet inbox` instead (`ironpet inbox --help`).")
        }
        if first.hasPrefix("--"), !guiOptions.contains(first) {
            return .reject("ironpet: unknown option \(first). It was not started.")
        }
        if !first.hasPrefix("-") {
            return .reject("ironpet: unknown command \(first). Commands: automations, notifications, inbox, memory, skills, mcp. It was not started.")
        }
        return .gui
    }
}
