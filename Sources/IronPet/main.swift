import AppKit
import IronPetCore
import SwiftUI

Log.fallbackSink = OSLogLog()

// `IronPet automations …`, `IronPet notifications …`, `IronPet inbox …`, `IronPet memory …` and `IronPet mcp` talk to the running app and never open a window.
if CommandLine.arguments.dropFirst().first == "automations" {
    exit(AutomationCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "notifications" {
    exit(NotificationCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "inbox" {
    exit(InboxCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "memory" {
    exit(MemoryCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "skills" {
    exit(SkillCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if ["mcp", "mcp-stdio"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    // A background job's session must not start or steer jobs, so its bridge asks for the job scope.
    exit(AutomationCLI.stdioBridge(path: MCPEndpoint.path(forScope: ProcessInfo.processInfo.environment[MCPEndpoint.scopeVariable])))
}

if CommandLine.arguments.contains("--schema-version") {
    // Used by scripts/bundle.sh, which records it in Info.plist for the update check.
    print(AppMigrations.latestVersion)
    exit(0)
}

if CommandLine.arguments.contains("--uninstall") {
    // Used by scripts/uninstall.sh: removes only ironpet's hooks and its login item, then exits.
    do {
        let changed = try HookInstaller().uninstall()
        print(changed.isEmpty ? "No ironpet hooks found" : changed.map { "Removed ironpet hooks from \($0.path)" }.joined(separator: "\n"))
    } catch {
        FileHandle.standardError.write(Data("Could not remove hooks: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    if LoginItem.isEnabled {
        LoginItem.set(false)
        print("Removed the login item")
    }
    exit(0)
}

// Anything else that is not an option would start a second GUI, and an automation that runs the binary with a removed
// subcommand would then start one per run. Fail instead.
if case .reject(let message) = LaunchArguments.route(CommandLine.arguments) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

MainActor.assumeIsolated { PetAPI.live = .onThisMac() }

if CommandLine.arguments.contains("--render-previews") {
    MainActor.assumeIsolated { PreviewRenderer.run(arguments: CommandLine.arguments) }
    exit(0)
}

// One GUI process per ironpet root. A second one hands over to the first and exits before it opens a window.
let instanceLock: SingleInstance
switch SingleInstance.acquire(at: Paths.root.appendingPathComponent("instance.lock")) {
case .acquired(let lock):
    instanceLock = lock
case .running(let pid):
    if let pid, let running = NSRunningApplication(processIdentifier: pid) { running.activate() }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
