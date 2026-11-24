import Foundation

/// Reads the Keychain once per meeting, off the main thread. A Keychain approval dialog would otherwise
/// freeze the app, and would reappear for every chunk.
package final class MeetingKeyCache: @unchecked Sendable { // `loaded` is touched only under `lock`.
    private let lock = NSLock()
    private var loaded: String??
    private let voiceKey: VoiceKey

    package init(voiceKey: VoiceKey) { self.voiceKey = voiceKey }

    package func key() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let key = voiceKey.load()
        loaded = .some(key)
        return key
    }

    package func forget() {
        lock.lock()
        loaded = nil
        lock.unlock()
    }
}

/// What a meeting summary run needs, shared by the live recorder and the regenerator.
@MainActor
package enum MeetingSummary {
    /// Only the meeting folder is shared, and every permission request is refused, so the agent can read and answer
    /// but not change files or run commands. ironpet writes summary.md itself. Its turns count as meeting summaries in the Usage tab.
    package static func makeRunner(_ agent: ACPAgent, spawner: ProcessSpawner) -> ACPBackend {
        let runner = ACPBackend(agent: agent, spawner: spawner)
        runner.restricted = true
        runner.usageFeature = .meetingSummary
        runner.onPermission = { _, respond in respond(decision) }
        return runner
    }

    /// Every permission request from the summary agent is refused.
    package nonisolated static let decision = ApprovalDecision.deny("Meeting summaries are read-only")

    /// The wording is `prompts/meeting-summary.md`. The three section headings and the action-item line format are parsed by
    /// `Tasks/ActionItems.swift`, so they are the contract for anyone who edits that file.
    package static func prompt(transcript: String) -> String {
        let limit = ConfigStore.shared.config.meetings.transcriptCharacters
        var body = transcript
        var note = ""
        if body.count > limit {
            body = String(body.suffix(limit))
            note = "\n(The start of a very long transcript was cut here. The full text is in transcript.md.)\n"
        }
        return Prompts.render(id: "meeting-summary", ["note": note, "transcript": body])
    }
}
