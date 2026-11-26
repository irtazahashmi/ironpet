import Foundation

/// The routes of the remote API (SPEC.md > Remote API). The Mac's `RemoteServer` registers the same strings.
public enum APIPath {
    public static let pair = "/v1/pair"
    public static func pairStatus(_ id: String) -> String { "/v1/pair/\(id)" }
    public static let deviceMe = "/v1/devices/me"
    /// The inbox. The routes keep the name they had when the inbox held suggestions for the task list, so a phone and a Mac on
    /// different versions still reach each other.
    public static let suggestions = "/v1/suggestions"
    /// Marks the item done.
    public static func acceptSuggestion(_ id: String) -> String { "/v1/suggestions/\(id)/accept" }
    /// Removes the item. The Mac calls it "reject".
    public static func rejectSuggestion(_ id: String) -> String { "/v1/suggestions/\(id)/reject" }
    public static let events = "/v1/events"
    /// The voice socket: audio from the phone, transcripts and spoken replies from the Mac.
    public static let voice = "/v1/voice"
    public static let pet = "/v1/pet"
    public static func trick(_ name: String) -> String { "/v1/pet/tricks/\(name)" }
    public static let bubbles = "/v1/bubbles"
    public static func bubbleAction(_ bubble: String, _ action: String) -> String { "/v1/bubbles/\(bubble)/actions/\(action)" }
    public static let agents = "/v1/agents"
    public static func agent(_ id: String) -> String { "/v1/agents/\(id)" }
    public static func acknowledgeAgent(_ id: String) -> String { "/v1/agents/\(id)/acknowledge" }
    public static func askAboutAgent(_ id: String) -> String { "/v1/agents/\(id)/ask" }
    /// The agents as records (`agent.list`, `agent.get`). `/v1/agents` above is the coding-agent sessions.
    public static let agentRecords = "/v1/agent-records"
    public static func agentRecord(_ id: String) -> String { "/v1/agent-records/\(id)" }
    /// The record a public id in chat names (`ironpet://meeting_9f3c1e`).
    public static func record(_ id: String) -> String { "/v1/records/\(id)" }
    public static let alerts = "/v1/alerts"
    public static let dismissAllAlerts = "/v1/alerts/dismiss-all"
    public static func dismissAlert(_ id: String) -> String { "/v1/alerts/\(id)/dismiss" }
    public static func askAboutAlert(_ id: String) -> String { "/v1/alerts/\(id)/ask" }
    public static let today = "/v1/today"
    public static let assetManifest = "/v1/assets/manifest"
    public static func asset(_ sha256: String) -> String { "/v1/assets/\(sha256)" }

    public static let chat = "/v1/chat/current"
    public static func chatMessage(_ id: String) -> String { "/v1/chat/messages/\(id)" }
    /// The image of an attachment message, as raw bytes.
    public static func chatMessageFile(_ id: String) -> String { "/v1/chat/messages/\(id)/file" }
    /// A preview of a file a reply named, by absolute path in the `path` query item.
    public static let filePreview = "/v1/files/preview"
    public static let chatThreads = "/v1/chat/threads"
    public static func chatThread(_ id: String) -> String { "/v1/chat/threads/\(id)" }
    public static let chatSend = "/v1/chat/current/messages"
    public static let chatStop = "/v1/chat/current/stop"
    public static func chatOpen(_ id: String) -> String { "/v1/chat/open/\(id)" }
    public static let chatNew = "/v1/chat/new"
    public static let chatOptions = "/v1/chat/options"
    public static func chatApproval(_ id: String) -> String { "/v1/chat/approvals/\(id)" }
    public static func chatForm(_ id: String) -> String { "/v1/chat/forms/\(id)" }
    public static func chatFormSubmit(_ id: String) -> String { "/v1/chat/forms/\(id)/submit" }
    public static func chatFormSkip(_ id: String) -> String { "/v1/chat/forms/\(id)/skip" }
    public static let uploads = "/v1/uploads"

    public static let automations = "/v1/automations"
    public static func automation(_ id: String) -> String { "/v1/automations/\(id)" }
    public static func automationHistory(_ id: String) -> String { "/v1/automations/\(id)/history" }
    public static func automationLog(_ id: String) -> String { "/v1/automations/\(id)/log" }
    public static func pauseAutomation(_ id: String) -> String { "/v1/automations/\(id)/pause" }
    public static func resumeAutomation(_ id: String) -> String { "/v1/automations/\(id)/resume" }
    public static func runAutomation(_ id: String) -> String { "/v1/automations/\(id)/run-now" }
    public static let requestAutomation = "/v1/automations/request"

    public static let memory = "/v1/memory"
    public static func memoryPage(_ ref: String) -> String { "/v1/memory/pages/\(ref)" }
    public static func memoryFact(_ ref: String) -> String { "/v1/memory/facts/\(ref)" }
    public static func memoryFactPin(_ ref: String) -> String { "/v1/memory/facts/\(ref)/pin" }
    public static let meetings = "/v1/meetings"
    public static let meetingState = "/v1/meetings/state"
    public static let stopMeeting = "/v1/meetings/stop"
    public static func meeting(_ id: String) -> String { "/v1/meetings/\(id)" }
    public static func meetingSummary(_ id: String) -> String { "/v1/meetings/\(id)/summary" }
    public static func meetingTranscript(_ id: String) -> String { "/v1/meetings/\(id)/transcript" }
    public static func regenerateMeeting(_ id: String) -> String { "/v1/meetings/\(id)/regenerate" }
    public static func askAboutMeeting(_ id: String) -> String { "/v1/meetings/\(id)/ask" }

    public static let screenStatus = "/v1/screen/status"
    public static let screenChanges = "/v1/screen/changes"
    public static func screenCapture(_ id: Int) -> String { "/v1/screen/captures/\(id)" }
    public static let screenSearch = "/v1/screen/search"
    public static let screenPause = "/v1/screen/pause"

    public static let settings = "/v1/settings"
    public static let settingsPets = "/v1/settings/pets"
    public static let settingsPet = "/v1/settings/pet"
    /// POST the raw bytes of a JPEG, PNG or HEIC image to make it the custom chat background.
    public static let settingsBackground = "/v1/settings/background"
    public static let usage = "/v1/usage"
}
