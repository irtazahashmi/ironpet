import Foundation

/// Reads the Keychain once per meeting, off the main thread. A Keychain approval dialog would otherwise
/// freeze the app, and would reappear for every chunk.
final class MeetingKeyCache: @unchecked Sendable { // `loaded` is touched only under `lock`.
    private let lock = NSLock()
    private var loaded: String??
    private let voiceKey: VoiceKey

    init(voiceKey: VoiceKey) { self.voiceKey = voiceKey }

    func key() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let key = voiceKey.load()
        loaded = .some(key)
        return key
    }

    func forget() {
        lock.lock()
        loaded = nil
        lock.unlock()
    }
}

/// What a meeting summary run needs, shared by the live recorder and the regenerator.
@MainActor
enum MeetingSummary {
    /// Only the meeting folder is shared, and every permission request is refused, so the agent can read and answer
    /// but not change files or run commands. ironpet writes summary.md itself. Its turns count as meeting summaries in the Usage tab.
    static func makeRunner(_ agent: ACPAgent, spawner: ProcessSpawner) -> ACPBackend {
        let runner = ACPBackend(agent: agent, spawner: spawner)
        runner.restricted = true
        runner.usageFeature = .meetingSummary
        runner.onPermission = { _, respond in respond(decision) }
        return runner
    }

    /// Every permission request from the summary agent is refused.
    nonisolated static let decision = ApprovalDecision.deny("Meeting summaries are read-only")

    static func prompt(transcript: String) -> String {
        let limit = 300_000
        var body = transcript
        var note = ""
        if body.count > limit {
            body = String(body.suffix(limit))
            note = "\n(The start of a very long transcript was cut here. The full text is in transcript.md.)\n"
        }
        return """
            Below is the transcript of a meeting. "Me" is the person who recorded it. "Them" is everyone else on the \
            call, recorded from one app, so several people can appear as "Them". When ironpet could tell the voices apart, \
            their lines start with a name, or with "Speaker 1", "Speaker 2" when the name is not known.

            Do not use any tools and do not change any files. Answer in Markdown, in exactly these three sections:

            ## Summary
            Three to six sentences on what the meeting was about and how it ended.

            ## Decisions
            One bullet per decision that was made. Write "None." if there were none.

            ## Action items
            A checklist of open action items, one per line, as `- [ ] <task> (owner: <Me, Them, or the name if \
            someone said it>, due: <date, only if one was mentioned>)`. Leave out "due" when no date was mentioned. \
            Add ", waiting: yes" inside the parentheses only to an item owned by someone other than Me when that work is for Me, delivers \
            something to Me, or blocks something Me owns. Otherwise leave out "waiting", and never add it to an item \
            owned by Me. Write "None." if there were none.

            Use only what is in the transcript. Transcripts can contain recognition errors, so do not guess names.
            \(note)
            --- transcript.md ---
            \(body)
            """
    }
}
