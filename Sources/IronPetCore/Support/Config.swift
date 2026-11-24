import Foundation
import IronPetKit
#if canImport(Combine)
import Combine
#endif

/// User settings in `~/.ironpet/config.json`. The file only needs the keys the user changed: whatever it has is
/// laid over the defaults below. Defaults are conservative: nothing that reaches the network or copies
/// credentials is on until the user turns it on.
package struct Config: Codable, Equatable {
    package init(
        pet: Pet = Pet(),
        chat: Chat = Chat(),
        window: Window = Window(),
        openIn: String = "auto",
        editors: [Editor] = [],
        hotkeys: Hotkeys = Hotkeys(),
        reminders: Reminders = Reminders(),
        integrations: Integrations = Integrations(),
        automations: Automations = Automations(),
        skills: Skills = Skills(),
        tasks: Tasks = Tasks(),
        jobs: Jobs = Jobs(),
        welcomeBack: WelcomeBack = WelcomeBack(),
        voice: Voice = Voice(),
        speech: Speech = Speech(),
        voiceMode: VoiceMode = VoiceMode(),
        meetings: Meetings = Meetings(),
        telegram: Telegram = Telegram(),
        screenCapture: ScreenCapture = ScreenCapture(),
        desktopControl: DesktopControl = DesktopControl(),
        memory: Memory = Memory(),
        remote: Remote = Remote()
    ) {
        self.pet = pet
        self.chat = chat
        self.window = window
        self.openIn = openIn
        self.editors = editors
        self.hotkeys = hotkeys
        self.reminders = reminders
        self.integrations = integrations
        self.automations = automations
        self.skills = skills
        self.tasks = tasks
        self.jobs = jobs
        self.welcomeBack = welcomeBack
        self.voice = voice
        self.speech = speech
        self.voiceMode = voiceMode
        self.meetings = meetings
        self.telegram = telegram
        self.screenCapture = screenCapture
        self.desktopControl = desktopControl
        self.memory = memory
        self.remote = remote
    }

    package struct Pet: Codable, Equatable {
        package init(name: String = "Ghost", sprite: String? = nil) {
            self.name = name
            self.sprite = sprite
        }

        package var name = "Ghost"
        /// Path to a sprite sheet in the Codex pet v2 layout. Unset: `~/.ironpet/pet/spritesheet.png`, else the
        /// bundled Ghost.
        package var sprite: String?
    }

    /// Global shortcuts like `"cmd+opt+g"`. An empty string turns a shortcut off.
    package struct Hotkeys: Codable, Equatable {
        package init(
            chat: String = "cmd+opt+g",
            captureWindow: String = "cmd+opt+shift+g",
            captureRegion: String = "cmd+opt+ctrl+g",
            voice: String = "cmd+opt+v",
            meeting: String = "",
            voiceMode: String = "cmd+opt+ctrl+v",
            copyVersion: String = "",
            dictation: String = "ctrl+opt+space"
        ) {
            self.chat = chat
            self.captureWindow = captureWindow
            self.captureRegion = captureRegion
            self.voice = voice
            self.meeting = meeting
            self.voiceMode = voiceMode
            self.copyVersion = copyVersion
            self.dictation = dictation
        }

        package var chat = "cmd+opt+g"
        package var captureWindow = "cmd+opt+shift+g"
        package var captureRegion = "cmd+opt+ctrl+g"
        /// Starts and stops a voice note (see `Voice.holdToTalk`). Only registered while voice notes are on.
        package var voice = "cmd+opt+v"
        /// Starts the meeting picker, or stops a running meeting. No default binding. Only registered while meeting
        /// transcripts are on.
        package var meeting = ""
        /// Starts and ends a voice conversation with the pet. Only registered while voice mode is on.
        package var voiceMode = "cmd+opt+ctrl+v"
        /// Copies the app version and commit to the clipboard. No default binding.
        package var copyVersion = ""
        /// Starts and stops dictation into whatever text field has focus in any app. Empty turns it off. Only
        /// registered while voice notes are on, because it transcribes with the same server.
        package var dictation = "ctrl+opt+space"
    }

    /// Voice notes: record the mic and send the audio to an OpenAI-compatible transcription server. The API key is
    /// not here; it lives in the Keychain (`VoiceKey`).
    package struct Voice: Codable, Equatable {
        package init(
            enabled: Bool = false,
            baseUrl: String = "http://localhost:8000/v1",
            model: String = "mlx-community/parakeet-tdt-0.6b-v3",
            holdToTalk: Bool = true
        ) {
            self.enabled = enabled
            self.baseUrl = baseUrl
            self.model = model
            self.holdToTalk = holdToTalk
        }

        /// Off by default: turning it on is what lets audio leave the Mac.
        package var enabled = false
        /// The server's base URL; `/audio/transcriptions` is added to it.
        package var baseUrl = "http://localhost:8000/v1"
        package var model = "mlx-community/parakeet-tdt-0.6b-v3"
        /// On: hold the shortcut to record and release to transcribe. Off: press once to start and again to stop.
        package var holdToTalk = true
    }

    /// Spoken replies: Ghost reads chat replies aloud with a voice from an OpenAI-compatible speech server. Uses the
    /// server in `voice` (base URL, Keychain key).
    package struct Speech: Codable, Equatable {
        package init(
            enabled: Bool = false,
            model: String = Speech.defaultModel,
            voice: String = Speech.defaultVoice,
            speed: Double = Speech.defaultSpeed
        ) {
            self.enabled = enabled
            self.model = model
            self.voice = voice
            self.speed = speed
        }

        /// Off by default: turning it on reads each reply to a chat message aloud, which sends its text to the voice
        /// server. With it off, text is sent only when the user presses a reply's speaker button.
        package var enabled = false
        package var model = Speech.defaultModel
        /// One of the model's voices, such as Kokoro's `am_puck` or OpenAI's `nova`.
        package var voice = Speech.defaultVoice
        /// Playback speed sent with each request; 1 is the model's normal pace.
        package var speed = Speech.defaultSpeed

        /// Whether a speech model is set, which is all the speaker button needs. `enabled` only governs reading
        /// replies aloud automatically.
        package var canSpeak: Bool { !model.trimmingCharacters(in: .whitespaces).isEmpty }

        package static let defaultModel = "mlx-community/Kokoro-82M-bf16"
        package static let defaultVoice = "am_puck"
        package static let defaultSpeed = 1.0
        package static let speedRange = 0.5...2.0
    }

    /// Voice mode: a spoken conversation with the pet on a shortcut. It listens through ironpet's microphone (or takes
    /// Wispr Flow's dictation), answers aloud through spoken replies' voice, and hands longer work to background jobs.
    package struct VoiceMode: Codable, Equatable {
        package init(
            enabled: Bool = false,
            listenWith: String = VoiceMode.ironpet,
            model: String = "",
            silenceSeconds: Int = 20,
            speakJobUpdates: Bool = true,
            idleShutdownMinutes: Int = 10,
            fastModelWords: [String] = VoiceMode.defaultFastModelWords
        ) {
            self.enabled = enabled
            self.listenWith = listenWith
            self.model = model
            self.silenceSeconds = silenceSeconds
            self.speakJobUpdates = speakJobUpdates
            self.idleShutdownMinutes = idleShutdownMinutes
            self.fastModelWords = fastModelWords
        }

        /// Off by default: it opens the microphone and sends what was said to the voice server and the agent.
        package var enabled = false
        /// `ironpet` (the app hears when you stop talking) or `wispr` (Wispr Flow's dictation is sent as it lands).
        package var listenWith = VoiceMode.ironpet
        /// The model the conversation's agent session uses. Empty: the agent's fastest.
        package var model = ""
        /// The conversation ends after this long with nothing said.
        package var silenceSeconds = 20
        /// Speak up when a job started by voice finishes, fails or needs an OK.
        package var speakJobUpdates = true
        /// The front desk's agent process is closed after this many minutes without a conversation.
        package var idleShutdownMinutes = 10
        /// With no `model` set, the front desk uses the first model whose id or name has one of these words, in this order.
        package var fastModelWords = VoiceMode.defaultFastModelWords

        package static let ironpet = "ironpet"
        package static let wispr = "wispr"
        package static let silenceRange = 5...120
        package static let idleShutdownRange = 1...120
        package static let defaultFastModelWords = ["haiku", "flash", "mini", "fast", "lite"]
        package static let maxFastModelWords = 20
    }

    /// Meeting transcripts: the mic and one app's audio go to the voice server in chunks, and an agent summarizes the
    /// result. Uses the server in `voice` (base URL, model, Keychain key).
    package struct Meetings: Codable, Equatable {
        package init(
            enabled: Bool = false,
            lastApp: String = "",
            summaryAgent: String = "claude",
            summaryModel: String? = nil,
            autoSummary: Bool = true,
            offerToRecordCalls: Bool = true,
            ignoredMicApps: [String] = [],
            recogniseSpeakers: Bool = false,
            transcriptCharacters: Int = Meetings.defaultTranscriptCharacters
        ) {
            self.enabled = enabled
            self.lastApp = lastApp
            self.summaryAgent = summaryAgent
            self.summaryModel = summaryModel
            self.autoSummary = autoSummary
            self.offerToRecordCalls = offerToRecordCalls
            self.ignoredMicApps = ignoredMicApps
            self.recogniseSpeakers = recogniseSpeakers
            self.transcriptCharacters = transcriptCharacters
        }

        /// Off by default: turning it on lets meeting audio leave the Mac and the transcript reach an agent.
        package var enabled = false
        /// Bundle id of the app recorded last time, or `"all"` for all system audio. Empty until the first meeting.
        package var lastApp = ""
        /// An ACP agent id from `AgentCatalog`, such as `"claude"` or `"cursor"`.
        package var summaryAgent = "claude"
        /// nil uses the agent's default model.
        package var summaryModel: String?
        /// Run the summary agent as soon as the transcript is final.
        package var autoSummary = true
        /// Ghost offers to record when another app holds the microphone for a call. Only applies with `enabled` on.
        package var offerToRecordCalls = true
        /// Bundle id prefixes of apps that never count as a call, on top of the built-in list in `CallApps`. Dictation
        /// and voice assistants go here. Applies to call offers and to holding back spoken replies.
        package var ignoredMicApps: [String] = []
        /// Splits "Them" into individual speakers and recognises voices the user has named. Off by default because
        /// voiceprints are biometric data. Turning it on downloads the models once.
        package var recogniseSpeakers = false
        /// The summary reads the last this many characters of a transcript. The start of a longer one is cut, and the summary says so.
        package var transcriptCharacters = Meetings.defaultTranscriptCharacters

        package static let defaultTranscriptCharacters = 300_000
        package static let transcriptCharactersRange = 20_000...2_000_000
    }

    /// Screen capture: ironpet reads the text of the window you are using through Accessibility and keeps it, redacted, in its local
    /// database. Agents you run read it through MCP tools. Off by default. With it off nothing is read and no permission prompt appears.
    package struct ScreenCapture: Codable, Equatable {
        package init(enabled: Bool = false, ocr: Bool = false, retentionDays: Int = 30, excludedApps: [String] = []) {
            self.enabled = enabled
            self.ocr = ocr
            self.retentionDays = retentionDays
            self.excludedApps = excludedApps
        }

        package var enabled = false
        /// When a window exposes no text, take a screenshot of it and read the text on this Mac. The image is never saved. Turning this
        /// on asks for Screen Recording permission.
        package var ocr = false
        /// Captures older than this are deleted.
        package var retentionDays = 30
        /// Bundle ids or names of apps never captured at all. Password managers are always excluded and do not need to be listed.
        package var excludedApps: [String] = []
    }

    /// Desktop control: agents you run in ironpet read and operate other apps through Accessibility (the `desktop_*` MCP tools). Off by
    /// default. Actions on elements that say send, pay, delete, submit or buy always wait for your approval.
    package struct DesktopControl: Codable, Equatable {
        package init(enabled: Bool = false) {
            self.enabled = enabled
        }

        package var enabled = false
    }

    package struct Reminders: Codable, Equatable {
        package init(paused: Bool = false, idleResetMinutes: Double = 5, snoozeMinutes: Double = 10) {
            self.paused = paused
            self.idleResetMinutes = idleResetMinutes
            self.snoozeMinutes = snoozeMinutes
        }

        package struct Item: Codable, Equatable {
            package init(enabled: Bool = true, minutes: Double) {
                self.enabled = enabled
                self.minutes = minutes
            }

            package var enabled = true
            package var minutes: Double
        }

        package var paused = false
        package var water = Item(minutes: 45)
        package var stretch = Item(minutes: 60)
        package var eyes = Item(minutes: 20)
        /// Being away from the keyboard this long resets every reminder.
        package var idleResetMinutes: Double = 5
        package var snoozeMinutes: Double = 10
    }

    package struct Automations: Codable, Equatable {
        package init(logRetentionDays: Int = 14, autoFix: Bool = true, autoApprove: Bool = false, ownRunLimit: Int = 50,
                     keptThreads: Int = 50, runTimeoutSeconds: Int = 900) {
            self.logRetentionDays = logRetentionDays
            self.autoFix = autoFix
            self.autoApprove = autoApprove
            self.ownRunLimit = ownRunLimit
            self.keptThreads = keptThreads
            self.runTimeoutSeconds = runTimeoutSeconds
        }

        /// Execution logs older than this many days are deleted.
        package var logRetentionDays = 14
        /// When an automation fails, send the error to the chat and ask the agent to fix it.
        package var autoFix = true
        /// Approve commands, scripts and prompts that an agent writes without asking. Off by default.
        package var autoApprove = false
        /// An automation's own agent thread without a known transcript file starts a fresh thread after this many runs.
        package var ownRunLimit = 50
        /// Threads kept per automation. Older ones are deleted after a run.
        package var keptThreads = 50
        /// Seconds an automation's agent run may take before it is stopped.
        package var runTimeoutSeconds = 900

        package static let ownRunLimitRange = 1...500
        package static let keptThreadsRange = 1...500
        package static let runTimeoutSecondsRange = 60...7_200
    }

    package struct Skills: Codable, Equatable {
        package init(autoUpdate: Bool = true) {
            self.autoUpdate = autoUpdate
        }

        /// Install the skills that are missing for the agents found on this Mac, and update installed ones when ironpet ships a newer text.
        package var autoUpdate = true
    }

    package struct Tasks: Codable, Equatable {
        package init(meetingSuggestions: Bool = true, dueReminders: Bool = true, keepDoneDays: Int = 30, quickFilters: [QuickFilter] = []) {
            self.meetingSuggestions = meetingSuggestions
            self.dueReminders = dueReminders
            self.keepDoneDays = keepDoneDays
            self.quickFilters = quickFilters
        }

        /// After a meeting summary, offer the action items that belong to "Me" as tasks. Nothing is added without a click.
        package var meetingSuggestions = true
        /// Ghost says when an open task is due today or overdue, once per due date. Held by `reminders.paused`.
        package var dueReminders = true
        /// Done tasks older than this many days are deleted, with their history.
        package var keepDoneDays = 30
        /// Saved queries the Tasks list offers as chips. The chat agent writes them through `task_filters_upsert`.
        package var quickFilters: [QuickFilter] = []
    }

    /// Background jobs: work an agent hands off to its own agent session (`jobs_start`), each with a task in the Tasks section.
    package struct Jobs: Codable, Equatable {
        package init(maxRunning: Int = 3, permissionTimeoutMinutes: Int = 10, turnTimeoutMinutes: Int = 60, retentionDays: Int = 30) {
            self.maxRunning = maxRunning
            self.permissionTimeoutMinutes = permissionTimeoutMinutes
            self.turnTimeoutMinutes = turnTimeoutMinutes
            self.retentionDays = retentionDays
        }

        /// Finished jobs older than this many days are deleted at launch.
        package var retentionDays = 30
        package static let retentionDaysRange = 1...365

        /// Minutes a job's agent may run before ironpet stops it and marks the job failed.
        package var turnTimeoutMinutes = 60
        package static let turnTimeoutRange = 1...1440

        /// Minutes a permission request from a job or an automation's own session waits for an answer. After that the agent gets
        /// its reject option and the run records that the request timed out.
        package var permissionTimeoutMinutes = 10

        package static let permissionTimeoutRange = 1...1440

        /// Jobs running at once. A job started past this waits in line.
        package var maxRunning = 3

        package static let maxRunningRange = 1...5
    }

    /// After the user has been away for `reminders.idleResetMinutes`, one bubble sums up what happened meanwhile. Built from
    /// ironpet's own activity log and stores; nothing is sent anywhere, so it is on by default.
    package struct WelcomeBack: Codable, Equatable {
        package init(enabled: Bool = true) {
            self.enabled = enabled
        }

        package var enabled = true
    }

    package struct Integrations: Codable, Equatable {
        package init(
            cursorHooks: Bool = false,
            claudeHooks: Bool = false,
            hooks: [String: Bool] = [:],
            githubAlerts: Bool = false,
            shareMCPSignIns: Bool = false
        ) {
            self.cursorHooks = cursorHooks
            self.claudeHooks = claudeHooks
            self.hooks = hooks
            self.githubAlerts = githubAlerts
            self.shareMCPSignIns = shareMCPSignIns
        }

        /// Status hooks in `~/.cursor/hooks.json`.
        package var cursorHooks = false
        /// Status hooks in `~/.claude/settings.json`.
        package var claudeHooks = false
        /// Watch switches for the other agents, by `HookInstaller.Agent` raw value (`"codex": true`).
        package var hooks: [String: Bool] = [:]
        /// Whether ironpet watches this agent. Cursor and Claude Code keep their own keys for older config files.
        package func watches(_ agent: HookInstaller.Agent) -> Bool {
            switch agent {
            case .cursor: return cursorHooks
            case .claude: return claudeHooks
            default: return hooks[agent.rawValue] ?? false
            }
        }

        package mutating func setWatches(_ on: Bool, _ agent: HookInstaller.Agent) {
            switch agent {
            case .cursor: cursorHooks = on
            case .claude: claudeHooks = on
            default: hooks[agent.rawValue] = on
            }
        }

        /// Poll every host `gh` is logged in to for PR, CI and review alerts.
        package var githubAlerts = false
        /// Copy cursor-agent MCP OAuth sign-ins between per-folder `mcp-auth.json` files before each chat.
        package var shareMCPSignIns = false
    }

    /// Chat with the pet from Telegram through the user's own bot. The bot token is not here; it lives in the
    /// Keychain (`TelegramToken`). Off by default: turning it on makes ironpet poll api.telegram.org.
    package struct Telegram: Codable, Equatable {
        package init(enabled: Bool = false, allowedUsers: [User] = []) {
            self.enabled = enabled
            self.allowedUsers = allowedUsers
        }

        package struct User: Codable, Equatable, Identifiable {
            package init(id: Int64, name: String, username: String? = nil) {
                self.id = id
                self.name = name
                self.username = username
            }

            package var id: Int64
            package var name: String
            package var username: String?
        }

        package var enabled = false
        /// Only messages from these Telegram user ids reach the chat.
        package var allowedUsers: [User] = []
    }

    /// The remote API a paired phone reaches over the Wi-Fi or the tailnet. Off by default: turning it on opens an HTTPS listener on the chosen
    /// network address and a plain one on 127.0.0.1, and both answer only requests with a device token (see SECURITY.md).
    package struct Remote: Codable, Equatable {
        package init(
            enabled: Bool = false,
            port: Int = Remote.defaultPort,
            address: String = "",
            machineName: String = "",
            baseUrl: String = ""
        ) {
            self.enabled = enabled
            self.port = port
            self.address = address
            self.machineName = machineName
            self.baseUrl = baseUrl
        }

        package var enabled = false
        /// Port of both listeners. Outside the hook server's 47321-47340 range, which has no per-device tokens.
        package var port = Remote.defaultPort
        /// Where the paired device reaches this Mac. Empty picks the first address of the Network list, Tailscale first. Otherwise one
        /// address of that list, a custom IPv4 address, or the URL of the user's own front such as `https://mac.tailnet.ts.net`.
        package var address = ""
        /// The Mac's name in the Allow bubble and the device list. Empty uses the name from System Settings.
        package var machineName = ""
        /// Replaced by `address`. A value left in an older config.json moves to `address` when the config loads, and this is cleared.
        package var baseUrl = ""

        package static let defaultPort = 47380
        package static let portRange = 1024...65_535
        /// The hook server walks up from 47321 to find a free port. The remote API never takes one of these.
        package static let reservedPorts = 47_321...47_340
    }

    /// An extra app for the "Open sessions in" picker. Without `urlTemplate` the folder is opened with the app;
    /// `{cwd}` in a template becomes the percent-encoded folder path.
    package struct Editor: Codable, Equatable {
        package init(name: String, bundleId: String, urlTemplate: String? = nil) {
            self.name = name
            self.bundleId = bundleId
            self.urlTemplate = urlTemplate
        }

        package var name: String
        package var bundleId: String
        package var urlTemplate: String?
    }

    package struct Chat: Codable, Equatable {
        package init(
            background: String = "default",
            customImage: String? = nil,
            pasteAttachmentChars: Int = Chat.defaultPasteChars,
            pasteAttachmentLines: Int = Chat.defaultPasteLines,
            sessionRolloverMB: Int = Chat.defaultRolloverMB,
            sessionRetentionDays: Int = Chat.defaultRetentionDays
        ) {
            self.background = background
            self.customImage = customImage
            self.pasteAttachmentChars = pasteAttachmentChars
            self.pasteAttachmentLines = pasteAttachmentLines
            self.sessionRolloverMB = sessionRolloverMB
            self.sessionRetentionDays = sessionRetentionDays
        }

        /// `"default"` (plain), a built-in id such as `"paws"`, or `"custom"` for the image in `customImage`.
        package var background = "default"
        /// File name of the imported image in `~/.ironpet/backgrounds`.
        package var customImage: String?
        /// A paste over this many characters becomes a `pasted-text.txt` attachment.
        package var pasteAttachmentChars = Chat.defaultPasteChars
        /// A paste over this many lines becomes a `pasted-text.txt` attachment.
        package var pasteAttachmentLines = Chat.defaultPasteLines
        /// The chat moves to a fresh agent session when the agent's transcript file passes this many megabytes.
        package var sessionRolloverMB = Chat.defaultRolloverMB
        /// Transcripts of earlier agent sessions of a chat are deleted this many days after their last write.
        package var sessionRetentionDays = Chat.defaultRetentionDays

        package static let defaultRolloverMB = 50
        package static let defaultRetentionDays = 14
        package static let rolloverMBRange = 1...10_000
        package static let retentionDaysRange = 1...365
        package static let defaultPasteChars = 4_000
        package static let defaultPasteLines = 60
        package static let pasteCharsRange = 500...100_000
        package static let pasteLinesRange = 10...2_000
    }

    /// Ghost's memory: entity pages in `ironpet.db`. After a chat goes quiet, a background pass sends the new messages to the agent
    /// that already had them, which only answers, and ironpet saves the lasting facts it names as notes. On by default: nothing
    /// reaches a provider that did not have it, but each pass spends quota, so it has its own switch and Usage feature.
    package struct Memory: Codable, Equatable {
        package init(
            reflect: Bool = true,
            reflectAgent: String? = nil,
            reflectModel: String? = nil,
            digestMinutes: Int = Memory.defaultDigestMinutes,
            reflectMaxNotes: Int = Memory.defaultReflectMaxNotes,
            reflectMaxInputChars: Int = Memory.defaultReflectMaxInputChars,
            reflectTimeoutSeconds: Int = Memory.defaultReflectTimeoutSeconds,
            recallBytesMe: Int = 4_000,
            recallBytesProject: Int = 6_000,
            recallBytesPeople: Int = 2_000,
            learnFromScreen: Bool = false,
            maxClaimsPerEntity: Int = Memory.defaultMaxClaimsPerEntity,
            noteMaxLength: Int = 240
        ) {
            self.reflect = reflect
            self.reflectAgent = reflectAgent
            self.reflectModel = reflectModel
            self.digestMinutes = digestMinutes
            self.reflectMaxNotes = reflectMaxNotes
            self.reflectMaxInputChars = reflectMaxInputChars
            self.reflectTimeoutSeconds = reflectTimeoutSeconds
            self.recallBytesMe = recallBytesMe
            self.recallBytesProject = recallBytesProject
            self.recallBytesPeople = recallBytesPeople
            self.learnFromScreen = learnFromScreen
            self.maxClaimsPerEntity = maxClaimsPerEntity
            self.noteMaxLength = noteMaxLength
        }

        package var reflect = true
        /// nil: each chat is read by its own agent, a meeting summary by the summary agent and an automation's answer by the agent
        /// that ran it. An ACP agent id: only text that went to that agent is read, by it.
        package var reflectAgent: String?
        /// nil: the agent's cheap model when it has one (`cheapModels`), else its default. Only used with `reflectAgent` set, since a
        /// model id means nothing to another agent.
        package var reflectModel: String?
        /// The digest reads what is new in chats, meetings and tasks this often (and the screen, when `learnFromScreen` is on).
        package var digestMinutes = Memory.defaultDigestMinutes
        /// Most notes one learning pass may save from a chat, meeting or automation answer.
        package var reflectMaxNotes = Memory.defaultReflectMaxNotes
        /// Characters of a chat, meeting summary or automation answer that a learning pass reads. The newest part is kept.
        package var reflectMaxInputChars = Memory.defaultReflectMaxInputChars
        /// Seconds a learning pass waits for its agent before it gives up and tries again later.
        package var reflectTimeoutSeconds = Memory.defaultReflectTimeoutSeconds
        /// Characters of notes that go into the chat's context, per file: about the user, about the project, and about people.
        package var recallBytesMe = 4_000
        package var recallBytesProject = 6_000
        package var recallBytesPeople = 2_000
        /// Off: the digest also reads the text of the user's screen captures, and only sends it to the agent the user picked for the digest.
        package var learnFromScreen = false
        /// A page with more valid claims than this is merged by the digest: the oldest unpinned facts are combined into fewer ones.
        package var maxClaimsPerEntity = Memory.defaultMaxClaimsPerEntity
        /// Most characters one memory note may have.
        package var noteMaxLength = 240

        package static let defaultReflectMaxNotes = 8
        package static let defaultReflectMaxInputChars = 24_000
        package static let defaultReflectTimeoutSeconds = 180
        package static let reflectMaxNotesRange = 1...20
        package static let reflectMaxInputCharsRange = 2_000...200_000
        package static let reflectTimeoutSecondsRange = 30...1_800
        package static let recallBytesRange = 500...50_000
        package static let digestMinutesRange = 15...1_440
        package static let maxClaimsPerEntityRange = 10...200
        package static let noteMaxLengthRange = 40...2_000

        /// Agents whose adapter offers a clearly cheap model in every session. Claude Code's `haiku` is its own alias for its
        /// smallest model. The others either list no models or only parameterized ones with no cheap tier, so they use their default.
        package static let cheapModels = ["claude": "haiku"]
        package static let defaultDigestMinutes = 60
        package static let defaultMaxClaimsPerEntity = 30

        /// Who reads text that `source` already had, and with which model. Nil when a set `reflectAgent` is another agent, so the
        /// text is skipped rather than sent to a provider that did not have it.
        package func reader(for source: String) -> (agent: String, model: String?)? {
            if let reflectAgent {
                guard reflectAgent == source else { return nil }
                return (reflectAgent, reflectModel ?? Self.cheapModels[reflectAgent])
            }
            return (source, Self.cheapModels[source])
        }
    }

    /// The ironpet window (chat, agents, tasks and the other sections).
    package struct Window: Codable, Equatable {
        package init(autoHide: Bool = false, appearance: String = Window.systemAppearance) {
            self.autoHide = autoHide
            self.appearance = appearance
        }

        /// Hide the window when another app becomes active, and bring it back when ironpet is activated again.
        /// Off by default: the window then stays as it is today.
        package var autoHide = false
        /// `"system"` (follow macOS), `"light"` or `"dark"`. Applied to the whole app, so the pet, its bubbles and the windows follow.
        package var appearance = Window.systemAppearance

        package static let systemAppearance = "system"
        package static let appearances = [systemAppearance, "light", "dark"]
    }

    package var pet = Pet()
    package var chat = Chat()
    package var window = Window()
    /// `"auto"` (the app that started the agent) or the bundle id of a fixed app.
    package var openIn = "auto"
    package var editors: [Editor] = []
    package var hotkeys = Hotkeys()
    package var reminders = Reminders()
    package var integrations = Integrations()
    package var automations = Automations()
    package var skills = Skills()
    package var tasks = Tasks()
    package var jobs = Jobs()
    package var welcomeBack = WelcomeBack()
    package var voice = Voice()
    package var speech = Speech()
    package var voiceMode = VoiceMode()
    package var meetings = Meetings()
    package var telegram = Telegram()
    package var screenCapture = ScreenCapture()
    package var desktopControl = DesktopControl()
    package var memory = Memory()
    package var remote = Remote()

    package static let file = Paths.root.appendingPathComponent("config.json")

    /// Settings that have no value until set, so the encoded defaults leave them out. `SettingsAPI.patch` accepts these.
    package static let optionalKeys: Set<String> = ["pet.sprite", "meetings.summaryModel", "chat.customImage", "memory.reflectAgent", "memory.reflectModel"]

    /// Reads the file, laying it over the defaults. An unreadable or invalid file gives the defaults plus an error.
    package static func load(from file: URL = Config.file) -> (config: Config, error: String?) {
        guard let data = try? Data(contentsOf: file) else { return (Config(), nil) }
        do {
            guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (Config(), "config.json must contain a JSON object")
            }
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
            let merged = try JSONSerialization.data(withJSONObject: merge(user, over: defaults))
            return (try JSONDecoder().decode(Config.self, from: merged).sanitized(), nil)
        } catch {
            NSLog("ironpet: ignoring invalid \(file.path): \(error)")
            return (Config(), "config.json is invalid, using defaults: \(Self.describe(error))")
        }
    }

    package func save(to file: URL = Config.file) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// The config with every value clamped into its range and every text trimmed. Loading and every change go through it.
    package func sanitized() -> Config {
        var c = self
        c.pet.name = c.pet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.pet.name.isEmpty { c.pet.name = Pet().name }
        for path in [\Reminders.water, \Reminders.stretch, \Reminders.eyes] {
            c.reminders[keyPath: path].minutes = max(1, c.reminders[keyPath: path].minutes)
        }
        if c.chat.background != ChatBackground.defaultID, c.chat.background != ChatBackground.customID,
           ChatBackground.builtIn(c.chat.background) == nil {
            c.chat.background = ChatBackground.defaultID
        }
        // A file name only: a hand-edited "../x" must not read or delete anything outside the backgrounds folder.
        if let file = c.chat.customImage {
            let name = (file as NSString).lastPathComponent
            c.chat.customImage = name.isEmpty || name.hasPrefix(".") ? nil : name
        }
        if c.chat.background == ChatBackground.customID, c.chat.customImage == nil { c.chat.background = ChatBackground.defaultID }
        c.chat.pasteAttachmentChars = min(Chat.pasteCharsRange.upperBound, max(Chat.pasteCharsRange.lowerBound, c.chat.pasteAttachmentChars))
        c.chat.pasteAttachmentLines = min(Chat.pasteLinesRange.upperBound, max(Chat.pasteLinesRange.lowerBound, c.chat.pasteAttachmentLines))
        c.chat.sessionRolloverMB = min(Chat.rolloverMBRange.upperBound, max(Chat.rolloverMBRange.lowerBound, c.chat.sessionRolloverMB))
        c.chat.sessionRetentionDays = min(Chat.retentionDaysRange.upperBound, max(Chat.retentionDaysRange.lowerBound, c.chat.sessionRetentionDays))
        if !Window.appearances.contains(c.window.appearance) { c.window.appearance = Window.systemAppearance }
        c.openIn = c.openIn.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.openIn.isEmpty { c.openIn = Config().openIn }
        c.editors = c.editors.filter { !$0.name.isEmpty && !$0.bundleId.isEmpty }
        c.reminders.idleResetMinutes = max(1, c.reminders.idleResetMinutes)
        c.reminders.snoozeMinutes = max(1, c.reminders.snoozeMinutes)
        c.automations.logRetentionDays = min(365, max(1, c.automations.logRetentionDays))
        c.tasks.keepDoneDays = min(365, max(1, c.tasks.keepDoneDays))
        c.jobs.maxRunning = min(Jobs.maxRunningRange.upperBound, max(Jobs.maxRunningRange.lowerBound, c.jobs.maxRunning))
        c.jobs.permissionTimeoutMinutes = min(Jobs.permissionTimeoutRange.upperBound, max(Jobs.permissionTimeoutRange.lowerBound, c.jobs.permissionTimeoutMinutes))
        c.jobs.turnTimeoutMinutes = min(Jobs.turnTimeoutRange.upperBound, max(Jobs.turnTimeoutRange.lowerBound, c.jobs.turnTimeoutMinutes))
        c.memory.reflectMaxNotes = min(Memory.reflectMaxNotesRange.upperBound, max(Memory.reflectMaxNotesRange.lowerBound, c.memory.reflectMaxNotes))
        c.memory.reflectMaxInputChars = min(Memory.reflectMaxInputCharsRange.upperBound, max(Memory.reflectMaxInputCharsRange.lowerBound, c.memory.reflectMaxInputChars))
        c.memory.reflectTimeoutSeconds = min(Memory.reflectTimeoutSecondsRange.upperBound, max(Memory.reflectTimeoutSecondsRange.lowerBound, c.memory.reflectTimeoutSeconds))
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(range.upperBound, max(range.lowerBound, value)) }
        c.memory.recallBytesMe = clamp(c.memory.recallBytesMe, Memory.recallBytesRange)
        c.memory.recallBytesProject = clamp(c.memory.recallBytesProject, Memory.recallBytesRange)
        c.memory.recallBytesPeople = clamp(c.memory.recallBytesPeople, Memory.recallBytesRange)
        c.memory.digestMinutes = clamp(c.memory.digestMinutes, Memory.digestMinutesRange)
        c.memory.maxClaimsPerEntity = clamp(c.memory.maxClaimsPerEntity, Memory.maxClaimsPerEntityRange)
        c.memory.noteMaxLength = clamp(c.memory.noteMaxLength, Memory.noteMaxLengthRange)
        c.jobs.retentionDays = clamp(c.jobs.retentionDays, Jobs.retentionDaysRange)
        c.voiceMode.idleShutdownMinutes = clamp(c.voiceMode.idleShutdownMinutes, VoiceMode.idleShutdownRange)
        var seen = Set<String>()
        c.voiceMode.fastModelWords = c.voiceMode.fastModelWords
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(VoiceMode.maxFastModelWords).map { $0 }
        c.automations.ownRunLimit = clamp(c.automations.ownRunLimit, Automations.ownRunLimitRange)
        c.automations.keptThreads = clamp(c.automations.keptThreads, Automations.keptThreadsRange)
        c.automations.runTimeoutSeconds = clamp(c.automations.runTimeoutSeconds, Automations.runTimeoutSecondsRange)
        c.meetings.transcriptCharacters = clamp(c.meetings.transcriptCharacters, Meetings.transcriptCharactersRange)
        c.voice.baseUrl = c.voice.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        c.voice.model = c.voice.model.trimmingCharacters(in: .whitespacesAndNewlines)
        c.speech.model = c.speech.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.speech.model.isEmpty { c.speech.model = Speech.defaultModel }
        c.speech.voice = c.speech.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.speech.voice.isEmpty { c.speech.voice = Speech.defaultVoice }
        c.speech.speed = c.speech.speed.isFinite
            ? min(Speech.speedRange.upperBound, max(Speech.speedRange.lowerBound, c.speech.speed)) : Speech.defaultSpeed
        if c.voiceMode.listenWith != VoiceMode.wispr { c.voiceMode.listenWith = VoiceMode.ironpet }
        c.voiceMode.model = c.voiceMode.model.trimmingCharacters(in: .whitespacesAndNewlines)
        c.voiceMode.silenceSeconds = min(VoiceMode.silenceRange.upperBound, max(VoiceMode.silenceRange.lowerBound, c.voiceMode.silenceSeconds))
        if c.meetings.summaryModel?.trimmingCharacters(in: .whitespaces).isEmpty == true { c.meetings.summaryModel = nil }
        c.meetings.ignoredMicApps = MicIgnoreList.normalized(c.meetings.ignoredMicApps)
        c.screenCapture.retentionDays = min(365, max(1, c.screenCapture.retentionDays))
        c.memory.reflectAgent = c.memory.reflectAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.memory.reflectAgent?.isEmpty == true { c.memory.reflectAgent = nil }
        c.memory.reflectModel = c.memory.reflectModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.memory.reflectModel?.isEmpty == true || c.memory.reflectAgent == nil { c.memory.reflectModel = nil }
        if !Remote.portRange.contains(c.remote.port) || Remote.reservedPorts.contains(c.remote.port) { c.remote.port = Remote.defaultPort }
        c.remote.baseUrl = c.remote.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.remote.address.trimmingCharacters(in: .whitespaces).isEmpty { c.remote.address = c.remote.baseUrl }
        c.remote.baseUrl = ""
        c.remote.address = c.remote.address.trimmingCharacters(in: .whitespacesAndNewlines)
        while c.remote.address.hasSuffix("/") { c.remote.address.removeLast() }
        c.remote.machineName = String(c.remote.machineName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return c
    }

    package static func merge(_ user: [String: Any], over base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in user {
            if let nested = value as? [String: Any], let baseNested = base[key] as? [String: Any] {
                result[key] = merge(nested, over: baseNested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    package static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}

/// The live config for the UI. Picks up hand edits to the file within a couple of seconds.
@MainActor
package final class ConfigStore {
    package static let shared = ConfigStore()

    /// Fires before `config` or `error` change.
    package let changes = ChangeSignal()
    package private(set) var config: Config {
        willSet { changes.send() }
        didSet { if config != oldValue { events?.publish(.settingsChanged) } }
    }
    /// Where changes are published for API clients.
    package weak var events: APIEventBus?
    package private(set) var error: String? { willSet { changes.send() } }
    private var stamp: Date?
    private var timer: Timer?

    /// False for a store that only lives in memory (tests, previews): it never reads or writes `config.json`.
    private let persists: Bool

    private init() {
        persists = true
        (config, error) = Config.load()
        stamp = Self.modificationDate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    /// A store that keeps `config` in memory only.
    package init(memory config: Config) {
        persists = false
        self.config = config.sanitized()
    }

    /// For `--render-previews`: uses `config` in memory only, never saves it, and stops watching the file.
    package func usePreview(_ config: Config) {
        timer?.invalidate()
        self.config = config
        error = nil
    }

    /// Applies `change`, clamps the result like loading does, and saves it. Every client's change takes this path.
    package func update(_ change: (inout Config) -> Void) {
        var next = config
        change(&next)
        next = next.sanitized()
        guard next != config else { return }
        guard persists else { config = next; return }
        if error != nil, FileManager.default.fileExists(atPath: Config.file.path) {
            // The file on disk didn't parse; keep the user's hand edits before replacing it.
            let backup = Config.file.deletingPathExtension().appendingPathExtension("invalid.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: Config.file, to: backup)
        }
        do {
            try next.save()
            error = nil
        } catch {
            self.error = "Could not save config.json: \(error.localizedDescription)"
        }
        config = next
        stamp = Self.modificationDate()
    }

    package func reloadIfChanged() {
        guard persists else { return }
        let current = Self.modificationDate()
        guard current != stamp else { return }
        stamp = current
        let (loaded, loadError) = Config.load()
        error = loadError
        if loaded != config { config = loaded }
    }

    private static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Config.file.path))?[.modificationDate] as? Date
    }
}

#if canImport(Combine)

extension ConfigStore: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif
