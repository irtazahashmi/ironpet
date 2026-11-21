import AppKit
import IronPetCore

/// Brings the app that owns a session to the front, opening its folder there when the app can.
enum SourceJumper {
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    @MainActor static func jump(to session: AgentSession) {
        open(Editors.target(for: session), folder: session.origin.workspace, itermSession: session.origin.itermSessionID,
             session: session)
    }

    /// What `open` does to the system, replaceable in tests.
    struct Effects {
        /// Opens the URL with its registered handler. False when no app handles it.
        var openURL: (URL) -> Bool
        /// Runs the program and reports whether it exited with status 0. Waits at most 2 seconds.
        var run: (_ executable: String, _ arguments: [String]) -> Bool
        var activate: (_ bundleID: String, _ folder: String?) -> Void
        /// A full path for a bare command name, or nil when it is not installed.
        var findExecutable: (_ name: String, _ bundleID: String) -> String?
        /// The git worktree root that contains a folder, or the folder itself when none does. Orca matches `path:` exactly.
        var worktreeRoot: (_ folder: String) -> String = { $0 }

        static let live = Effects(
            openURL: { url in
                guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
                NSWorkspace.shared.open(url)
                return true
            },
            run: { executable, arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                do { try process.run() } catch {
                    NSLog("ironpet: could not run \(executable): \(error)")
                    return false
                }
                if done.wait(timeout: .now() + 2) == .timedOut {
                    process.terminate()
                    NSLog("ironpet: \(executable) timed out")
                    return false
                }
                return process.terminationStatus == 0
            },
            activate: SourceJumper.activate,
            findExecutable: SourceJumper.findExecutable,
            worktreeRoot: SourceJumper.worktreeRoot
        )
    }

    static func open(
        _ target: OpenTarget, folder: String?, itermSession: String? = nil, session: AgentSession? = nil,
        t3EnvironmentID: () -> String? = { Editors.t3EnvironmentID() }, effects: Effects = .live
    ) {
        if target.bundleID == Editors.itermID, let iterm = itermSession, !iterm.isEmpty, focusItermSession(iterm) {
            // AppleScript `activate` can lose to another app taking focus; ask again through AppKit.
            NSRunningApplication.runningApplications(withBundleIdentifier: Editors.itermID).first?
                .activate(options: [.activateAllWindows])
            return
        }
        let folder = folder.flatMap { $0.isEmpty ? nil : $0 }
        if target.bundleID == Editors.finderID {
            if let folder { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
            else { effects.activate(target.bundleID, nil) }
            return
        }
        let commandFolder = target.bundleID == Editors.orcaID ? folder.map(effects.worktreeRoot) : folder
        if let command = target.command, let arguments = Editors.arguments(command, target: target, session: session, folder: commandFolder) {
            runCommand(command, arguments, bundleID: target.bundleID, effects: effects)
            effects.activate(target.bundleID, nil)
            if let followUp = target.followUp,
               let more = Editors.arguments(followUp, target: target, session: session, folder: commandFolder) {
                runCommand(followUp, more, bundleID: target.bundleID, effects: effects)
            }
            return
        }
        if target.command == nil, let template = target.urlTemplate,
           let text = Editors.link(template, target: target, session: session, folder: folder, t3EnvironmentID: t3EnvironmentID),
           let url = URL(string: text), effects.openURL(url) {
            return
        }
        effects.activate(target.bundleID, target.folderFallback ? folder : nil)
    }

    /// Runs one command and logs a failure once. The caller activates the app either way.
    private static func runCommand(_ command: OpenCommand, _ arguments: [String], bundleID: String, effects: Effects) {
        guard let executable = effects.findExecutable(command.executable, bundleID) else {
            NSLog("ironpet: \(command.executable) not found, only activating \(bundleID)")
            return
        }
        if !effects.run(executable, arguments) {
            NSLog("ironpet: \(command.executable) \(arguments.prefix(2).joined(separator: " ")) failed")
        }
    }

    /// Walks up from `folder` to the first folder holding `.git` (a directory, or a file in a linked worktree).
    private static func worktreeRoot(_ folder: String) -> String {
        var url = URL(fileURLWithPath: folder).standardizedFileURL
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return folder
    }

    private static func activate(bundleID: String, opening folder: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let folder {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
    }

    /// Looks for `name` in `PATH`, the usual install folders and the app bundle's own folders. Only a bare name is
    /// accepted, so nothing from a session can pick the program.
    private static func findExecutable(_ name: String, bundleID: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        var folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cargo/bin"]
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            folders += ["Contents/MacOS", "Contents/Resources", "Contents/Resources/bin"].map { app.appendingPathComponent($0).path }
        }
        return folders.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `ITERM_SESSION_ID` looks like `w0t1p0:<uuid>`; AppleScript exposes the uuid as the session id.
    private static func focusItermSession(_ raw: String) -> Bool {
        let uuid = raw.split(separator: ":").last.map(String.init) ?? raw
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s is "\(uuid)" then
                  select w
                  select t
                  select s
                  activate
                  return true
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { NSLog("ironpet: iTerm jump failed \(error)") }
        return result?.booleanValue == true
    }
}
