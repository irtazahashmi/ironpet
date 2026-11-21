import Foundation

package enum Paths {
    package static let home = FileManager.default.homeDirectoryForCurrentUser
    /// `~/.ironpet`. `IRONPET_ROOT` moves it so a second copy of the app, such as an end-to-end test run, keeps its own port,
    /// token, settings and threads.
    package static let root = ProcessInfo.processInfo.environment["IRONPET_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent(".ironpet")
    package static let isIsolated = ProcessInfo.processInfo.environment["IRONPET_ROOT"] != nil
    package static let bin = root.appendingPathComponent("bin")
    package static let hookScript = bin.appendingPathComponent("ironpet-hook")
    package static let portFile = root.appendingPathComponent("port")
    package static let tokenFile = root.appendingPathComponent("token")
    /// One folder per meeting: the chunk WAVs, `transcript.md` and `summary.md`.
    package static let meetings = root.appendingPathComponent("meetings")
    /// Files sent to the Telegram bot, one folder per Telegram chat.
    package static let telegramFiles = root.appendingPathComponent("telegram/files")
    /// Screenshots and attachments the agent may read. Chat passes it to the agent as an extra folder.
    package static let screenshots = root.appendingPathComponent("screenshots")
    package static let attachments = screenshots.appendingPathComponent("attachments")
    package static let petDir = root.appendingPathComponent("pet")
    package static let cursorHooks = home.appendingPathComponent(".cursor/hooks.json")
    package static let claudeSettings = home.appendingPathComponent(".claude/settings.json")

    package static func ensureRoot() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }
}
