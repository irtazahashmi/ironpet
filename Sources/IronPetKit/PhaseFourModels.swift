import Foundation

// The phase 4 resources: automations, meetings and settings. The Mac encodes these types for its routes and the phone decodes them.
// Keys are snake_case like the other resources, except `RemoteConfig`, which keeps the names of `config.json` because
// `PATCH /v1/settings` takes a merge patch written in those names.

// MARK: Automations

/// One run of an automation, as the history shows it.
public struct RemoteAutomationRun: Codable, Equatable, Hashable, Sendable {
    public var date: Date
    /// `fired`, `ok`, `failed`, `baseline`, `skipped` or `waiting`.
    public var outcome: String
    public var output: String

    public init(date: Date, outcome: String, output: String = "") { self.date = date; self.outcome = outcome; self.output = output }
}

/// `GET /v1/automations` and `GET /v1/automations/<id>`.
public struct RemoteAutomation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// One line about the trigger, such as "daily at 09:00".
    public var trigger: String
    /// The trigger type: `daily`, `interval`, `once`, `poll`, `script`, `stream` or `inbox`.
    public var triggerType: String
    /// The action type: `bubble`, `prompt`, `shell`, `digest` or `none`.
    public var action: String
    public var createdBy: String
    public var nextRun: Date?
    public var lastRun: RemoteAutomationRun?
    /// `pending` or `rejected` while the Mac waits for the user to press Approve. Only the Mac can answer.
    public var approval: String?
    /// For a stream automation: `running`, `restarting` or `stopped`.
    public var stream: String?
    public var lastEvent: Date?
    /// Detail only: the command, script or prompt that waits for approval.
    public var approvalDetail: String?
    /// Detail only: the automation as pretty JSON.
    public var definition: String?
    /// The public `auto_<hex>` id. Nil from a Mac older than record ids.
    public var ref: String?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, trigger, action, approval, stream, definition, ref
        case triggerType = "trigger_type"
        case createdBy = "created_by"
        case nextRun = "next_run"
        case lastRun = "last_run"
        case lastEvent = "last_event"
        case approvalDetail = "approval_detail"
    }

    public init(id: String, name: String, enabled: Bool = true, trigger: String = "", triggerType: String = "daily", action: String = "bubble",
                createdBy: String = "user", nextRun: Date? = nil, lastRun: RemoteAutomationRun? = nil, approval: String? = nil,
                stream: String? = nil, lastEvent: Date? = nil, approvalDetail: String? = nil, definition: String? = nil,
                ref: String? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.trigger = trigger; self.triggerType = triggerType; self.action = action
        self.createdBy = createdBy; self.nextRun = nextRun; self.lastRun = lastRun; self.approval = approval; self.stream = stream
        self.lastEvent = lastEvent; self.approvalDetail = approvalDetail; self.definition = definition; self.ref = ref
    }

    /// The Mac still has to press Approve before this runs.
    public var waitsForApproval: Bool { approval != nil }
}

public struct RemoteAutomationLogEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var automation: String
    public var date: Date
    public var duration: Double
    public var outcome: String
    public var summary: String
    public var detail: String

    public init(id: Int, automation: String, date: Date, duration: Double = 0, outcome: String, summary: String, detail: String = "") {
        self.id = id; self.automation = automation; self.date = date; self.duration = duration; self.outcome = outcome
        self.summary = summary; self.detail = detail
    }
}

/// `POST /v1/automations/<id>/run-now`.
public struct RemoteAutomationRunResult: Codable, Equatable, Sendable {
    public var id: String
    /// `started`, or `waiting for approval`.
    public var status: String
    public init(id: String, status: String) { self.id = id; self.status = status }
}

// MARK: Meetings

/// `GET /v1/meetings`.
public struct RemoteMeeting: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var date: Date
    public var preview: String
    public var hasSummary: Bool
    public var hasTranscript: Bool
    /// The audio chunks are still on the Mac, so the transcript can be made again. The phone never gets the audio.
    public var hasAudio: Bool
    /// The meeting is being recorded or summarized now.
    public var active: Bool
    /// The public `meeting_<hex>` id. Nil from a Mac older than record ids.
    public var ref: String?
    /// The title the user gave the meeting on the Mac. Nil when there is none or the Mac is older.
    public var title: String?

    enum CodingKeys: String, CodingKey {
        case id, date, preview, active, ref, title
        case hasSummary = "has_summary"
        case hasTranscript = "has_transcript"
        case hasAudio = "has_audio"
    }

    public init(id: String, date: Date, preview: String = "", hasSummary: Bool = false, hasTranscript: Bool = false, hasAudio: Bool = false,
                active: Bool = false, ref: String? = nil, title: String? = nil) {
        self.title = title
        self.id = id; self.date = date; self.preview = preview; self.hasSummary = hasSummary; self.hasTranscript = hasTranscript
        self.hasAudio = hasAudio; self.active = active; self.ref = ref
    }
}

/// `GET /v1/meetings/<id>/summary` and `/transcript`: Markdown text.
public struct RemoteMeetingText: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

/// `GET /v1/meetings/state`.
public struct RemoteMeetingState: Codable, Equatable, Sendable {
    /// `idle`, `choosing`, `recording`, `finishing`, `summarizing` or `done`.
    public var phase: String
    public var appName: String
    public var startedAt: Date?
    public var chunksDone: Int
    public var chunksWaiting: Int
    public var chunksFailed: Int
    /// The meeting whose transcript or summary is being made again.
    public var regenerating: String?
    /// Why the last rebuild of a meeting failed, by meeting id.
    public var regenerationErrors: [String: String]

    /// Recording or finishing a recording: the one state in which the phone may send stop.
    public var isRecording: Bool { phase == "recording" }

    enum CodingKeys: String, CodingKey {
        case phase, regenerating
        case appName = "app_name"
        case startedAt = "started_at"
        case chunksDone = "chunks_done"
        case chunksWaiting = "chunks_waiting"
        case chunksFailed = "chunks_failed"
        case regenerationErrors = "regeneration_errors"
    }

    public init(phase: String = "idle", appName: String = "", startedAt: Date? = nil, chunksDone: Int = 0, chunksWaiting: Int = 0,
                chunksFailed: Int = 0, regenerating: String? = nil, regenerationErrors: [String: String] = [:]) {
        self.phase = phase; self.appName = appName; self.startedAt = startedAt; self.chunksDone = chunksDone
        self.chunksWaiting = chunksWaiting; self.chunksFailed = chunksFailed; self.regenerating = regenerating
        self.regenerationErrors = regenerationErrors
    }
}

// MARK: Settings

/// `GET /v1/settings`: the part of `config.json` the phone may show. `PATCH /v1/settings` takes a merge patch over the keys the phone may
/// change. Anything else, such as `voice.baseUrl`, is not in this type and a patch that names it gets 403.
public struct RemoteConfig: Codable, Equatable, Sendable {
    public struct Pet: Codable, Equatable, Sendable {
        public var name: String
        public var sprite: String?
        public init(name: String = "Ghost", sprite: String? = nil) { self.name = name; self.sprite = sprite }
    }

    public struct Reminder: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var minutes: Double
        public init(enabled: Bool = true, minutes: Double) { self.enabled = enabled; self.minutes = minutes }
    }

    public struct Reminders: Codable, Equatable, Sendable {
        public var paused: Bool
        public var water: Reminder
        public var stretch: Reminder
        public var eyes: Reminder
        public var idleResetMinutes: Double
        public var snoozeMinutes: Double
        public init(paused: Bool = false, water: Reminder = Reminder(minutes: 45), stretch: Reminder = Reminder(minutes: 60),
                    eyes: Reminder = Reminder(minutes: 20), idleResetMinutes: Double = 5, snoozeMinutes: Double = 10) {
            self.paused = paused; self.water = water; self.stretch = stretch; self.eyes = eyes
            self.idleResetMinutes = idleResetMinutes; self.snoozeMinutes = snoozeMinutes
        }
    }

    public struct Tasks: Codable, Equatable, Sendable {
        public var meetingSuggestions: Bool
        public init(meetingSuggestions: Bool = true) {
            self.meetingSuggestions = meetingSuggestions
        }
    }

    public struct Switch: Codable, Equatable, Sendable {
        public var enabled: Bool
        public init(enabled: Bool = false) { self.enabled = enabled }
    }

    public struct Speech: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var voice: String
        public init(enabled: Bool = false, voice: String = "") { self.enabled = enabled; self.voice = voice }
    }

    public struct Chat: Codable, Equatable, Sendable {
        public var background: String
        public init(background: String = "default") { self.background = background }
    }

    /// Whether the Mac tracks coding agents. Shown only: hooks are not changed from the phone. A Mac that predates the switch
    /// does not send it, which reads as on.
    public struct Agents: Codable, Equatable, Sendable {
        public var trackAgents: Bool
        public init(trackAgents: Bool = true) { self.trackAgents = trackAgents }
        public init(from decoder: Decoder) throws {
            trackAgents = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .trackAgents) ?? true
        }
    }

    public var pet: Pet
    public var reminders: Reminders
    public var tasks: Tasks
    public var welcomeBack: Switch
    public var speech: Speech
    public var chat: Chat
    /// Shown, and the phone can only turn it off.
    public var screenCapture: Switch
    /// Shown, and the phone can only turn it off.
    public var meetings: Switch
    public var agents: Agents

    public init(pet: Pet = Pet(), reminders: Reminders = Reminders(), tasks: Tasks = Tasks(), welcomeBack: Switch = Switch(enabled: true),
                speech: Speech = Speech(), chat: Chat = Chat(), screenCapture: Switch = Switch(), meetings: Switch = Switch(),
                agents: Agents = Agents()) {
        self.pet = pet; self.reminders = reminders; self.tasks = tasks; self.welcomeBack = welcomeBack; self.speech = speech
        self.chat = chat; self.screenCapture = screenCapture; self.meetings = meetings; self.agents = agents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pet = try c.decode(Pet.self, forKey: .pet)
        reminders = try c.decode(Reminders.self, forKey: .reminders)
        tasks = try c.decode(Tasks.self, forKey: .tasks)
        welcomeBack = try c.decode(Switch.self, forKey: .welcomeBack)
        speech = try c.decode(Speech.self, forKey: .speech)
        chat = try c.decode(Chat.self, forKey: .chat)
        screenCapture = try c.decode(Switch.self, forKey: .screenCapture)
        meetings = try c.decode(Switch.self, forKey: .meetings)
        agents = try c.decodeIfPresent(Agents.self, forKey: .agents) ?? Agents()
    }
}

/// One pet of the gallery. The id is opaque: pass it back to `POST /v1/settings/pet`.
public struct RemotePetChoice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var builtIn: Bool
    public var selected: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, selected
        case builtIn = "built_in"
    }

    public init(id: String, name: String, builtIn: Bool = false, selected: Bool = false) {
        self.id = id; self.name = name; self.builtIn = builtIn; self.selected = selected
    }
}

/// `GET /v1/usage`.
public struct RemoteUsage: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Hashable, Identifiable, Sendable {
        public var feature: String
        public var model: String
        public var currency: String?
        public var requests: Int
        public var totalTokens: Int?
        public var cost: Double?

        public var id: String { "\(feature)|\(model)" }

        enum CodingKeys: String, CodingKey {
            case feature, model, currency, requests, cost
            case totalTokens = "total_tokens"
        }

        public init(feature: String, model: String, currency: String? = nil, requests: Int, totalTokens: Int? = nil, cost: Double? = nil) {
            self.feature = feature; self.model = model; self.currency = currency; self.requests = requests
            self.totalTokens = totalTokens; self.cost = cost
        }
    }

    public var days: Int
    public var rows: [Row]
    public var todayCost: Double
    public var rangeCost: Double
    public var hasCost: Bool

    enum CodingKeys: String, CodingKey {
        case days, rows
        case todayCost = "today_cost"
        case rangeCost = "range_cost"
        case hasCost = "has_cost"
    }

    public init(days: Int = 7, rows: [Row] = [], todayCost: Double = 0, rangeCost: Double = 0, hasCost: Bool = false) {
        self.days = days; self.rows = rows; self.todayCost = todayCost; self.rangeCost = rangeCost; self.hasCost = hasCost
    }
}

// MARK: Response wrappers

public struct AutomationListResponse: Codable, Equatable, Sendable {
    public var automations: [RemoteAutomation]
    public init(automations: [RemoteAutomation]) { self.automations = automations }
}

public struct AutomationHistoryResponse: Codable, Equatable, Sendable {
    public var history: [RemoteAutomationRun]
    public init(history: [RemoteAutomationRun]) { self.history = history }
}

public struct AutomationLogResponse: Codable, Equatable, Sendable {
    public var log: [RemoteAutomationLogEntry]
    public init(log: [RemoteAutomationLogEntry]) { self.log = log }
}

public struct MeetingListResponse: Codable, Equatable, Sendable {
    public var meetings: [RemoteMeeting]
    public init(meetings: [RemoteMeeting]) { self.meetings = meetings }
}

public struct PetChoiceListResponse: Codable, Equatable, Sendable {
    public var pets: [RemotePetChoice]
    public init(pets: [RemotePetChoice]) { self.pets = pets }
}
