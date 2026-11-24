import Foundation

/// The messages ironpet sends to the chat agent about automations: a request to create one, and a request to fix one that failed.
/// The wording is `prompts/automation-new.md`, `automation-fix.md` and `automation-cli.md`. The code fills in the values and
/// decides whether the command-line line is there at all.
package enum AutomationAgentPrompts {
    /// How the agent can reach the automation tools when its MCP connection is missing. Empty without an executable.
    package static func cli(_ executable: String?) -> String {
        guard let executable else { return "" }
        return "\n" + Prompts.render(id: "automation-cli", ["executable": executable])
    }

    package static func newAutomation(_ request: String, executable: String? = Bundle.main.executablePath) -> String {
        Prompts.render(id: "automation-new", [
            "request": request.trimmingCharacters(in: .whitespacesAndNewlines),
            "cli": cli(executable),
        ])
    }

    /// `error` is output from the failed run. It can contain text from the network, so the message marks it as data.
    package static func fix(_ automation: Automation, trigger: String, error: String, executable: String? = Bundle.main.executablePath) -> String {
        Prompts.render(id: "automation-fix", [
            "name": automation.name,
            "id": automation.id,
            "trigger": trigger,
            "error": String(error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3000)),
            "cli": cli(executable),
        ])
    }
}
