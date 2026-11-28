import Foundation

/// One quick-chat thread with the pet, driven over ACP by whichever coding agent the user picked.
@MainActor
package final class ChatSession {
    /// Fires before any observed property changes, as `@Published` did. The Mac `ObservableObject` conformance forwards it to SwiftUI.
    package let changes = ChangeSignal()

    package enum State { case idle, running, done, failed }

    package struct Item: Identifiable, Codable, Equatable {
        package init(
            id: UUID = UUID(),
            kind: Kind,
            date: Date? = Date(),
            origin: String? = nil,
            reply: Reply? = nil,
            selection: FrontSelection? = nil,
            meta: [ItemMeta]? = nil,
            metaSent: Bool? = nil
        ) {
            self.id = id
            self.kind = kind
            self.date = date
            self.origin = origin
            self.reply = reply
            self.selection = selection
            self.meta = meta
            self.metaSent = metaSent
        }

        package enum Kind: Codable, Equatable {
            case user(String)
            case screenshot(String)
            case assistant(String)
            case tool(String, ok: Bool?)
            case error(String)
            /// A form the agent asked and the user answered or skipped.
            case form(ElicitationRecord)
            /// A system notice from IronPet. The first line is the visible label, the rest is shown when it is expanded.
            /// Empty text means the item only carries `meta` and draws nothing.
            case notice(String)
        }
        package var id = UUID()
        package var kind: Kind
        package var date: Date? = Date()
        /// The `client` of the `ChatOrigin` a user message came from when it was not typed here. Nil for the Mac.
        package var origin: String?
        /// The earlier message this one answers, when the user used Reply.
        package var reply: Reply?
        /// Text selected in another app that went with this user message. Older saved threads lack it.
        package var selection: FrontSelection?
        /// Context for the agent that the chat never draws. Set only by IronPet code.
        package var meta: [ItemMeta]?
        /// True once `meta` has gone to the agent in a turn.
        package var metaSent: Bool?
    }

    /// A reference to an earlier message, kept with the message that answers it. It stores the full text, so the agent
    /// still gets the original after the transcript scrolls or the thread is reopened.
    package struct Reply: Codable, Equatable {
        package init(itemID: UUID, sender: String, text: String, date: Date? = nil, selection: Bool? = nil, fromUser: Bool? = nil) {
            self.itemID = itemID
            self.sender = sender
            self.text = text
            self.date = date
            self.selection = selection
            self.fromUser = fromUser
        }

        /// The id of the original item. The quote scrolls to it while it is in the transcript.
        package var itemID: UUID
        /// "You" or the pet's name.
        package var sender: String
        /// The original message, or only the selected part of it when `selection` is true.
        package var text: String
        package var date: Date?
        /// True when the user selected part of the message and asked about that.
        package var selection: Bool? = nil
        /// True when the user wrote the original. Older saved threads lack it and fall back to the sender name.
        package var fromUser: Bool? = nil
    }

    package struct QueuedMessage: Identifiable {
        package init(
            text: String,
            attachments: [URL],
            origin: ChatOrigin? = nil,
            reply: Reply? = nil,
            selection: FrontSelection? = nil,
            automation: String? = nil,
            notice: Bool = false,
            spoken: Bool = false,
            readAloudBySender: Bool = false
        ) {
            self.text = text
            self.attachments = attachments
            self.origin = origin
            self.reply = reply
            self.selection = selection
            self.automation = automation
            self.notice = notice
            self.spoken = spoken
            self.readAloudBySender = readAloudBySender
        }

        package let id = UUID()
        package let text: String
        package let attachments: [URL]
        /// Who sent it when it was not typed on the Mac. Those are never put back in the Mac input.
        package var origin: ChatOrigin? = nil
        package var reply: Reply? = nil
        /// Text selected in another app when the chat opened. Mac local sends only.
        package var selection: FrontSelection? = nil
        /// The id of the automation that sent the message. Those are never put back in the Mac input.
        package var automation: String? = nil
        /// The user said it aloud, so its reply starts with a summary that is read aloud.
        package var spoken = false
        /// The client that sent it reads the reply aloud, so the reply starts with a summary the client reads and the turn waits for
        /// its turn instead of steering a running one. The Mac itself says nothing.
        package var readAloudBySender = false
        /// A turn that only delivers pending system notices. It has no text and never reaches the draft.
        package var notice = false
        /// Whether a running turn can take it. Automations and notices wait for the turn to end.
        package var steerable: Bool { automation == nil && !notice && !readAloudBySender }
    }

    /// What happened to a turn that an automation started, for `onAutomation`.
    package enum AutomationEvent: Equatable {
        case started
        case finished
        /// The reply was the task review's "nothing to do" line. The chat removed the prompt and the reply.
        case noChange
        case failed(String)
        /// The user or the chat ended it before or during the run. Not a fault in the automation.
        case cancelled(String)
    }

    /// What happened to a turn that another client started, for `onTurn`.
    package enum TurnEvent: Equatable, Codable {
        /// The agent was busy, so the message waits its turn.
        case queued
        case started
        /// The turn needs an approval. The Mac shows the same card.
        case approval(id: UUID, title: String, detail: String)
        /// An approval card was answered, here or on the Mac, or went away because the turn ended.
        case approvalDecided(id: UUID, outcome: ApprovalOutcome)
        /// The turn ended; the text is the last thing the agent wrote.
        case finished(String?)
        case failed(String)
    }

    package enum ApprovalOutcome: Equatable, Codable { case allowed, denied, ended }

    package nonisolated static let automationOrigin = ChatOrigin.automationClient
    /// A prompt or follow-up that a background job ran (`JobService`).
    package nonisolated static let jobOrigin = ChatOrigin.jobClient
    /// A message the user said aloud (`SpokenMessageController`).
    package nonisolated static let voiceOrigin = ChatOrigin.voiceClient

    package struct Approval: Identifiable {
        package init(title: String, detail: String, options: [PermissionOption] = [], responders: [(ApprovalDecision) -> Void]) {
            self.title = title
            self.detail = detail
            self.options = options
            self.responders = responders
        }

        package let id = UUID()
        package let title: String
        package let detail: String
        /// Exactly the answers the agent offered. Empty for a request that came without any.
        package let options: [PermissionOption]
        /// One request, one card, one answer: the option ids belong to the request that offered them.
        package var responders: [(ApprovalDecision) -> Void]

        package func respond(_ decision: ApprovalDecision) {
            responders.forEach { $0(decision) }
        }
    }

    /// A form the agent is waiting on (`elicitation/create`), with what the user has entered so far.
    package struct PendingForm: Identifiable {
        package init(form: ElicitationForm, answers: ElicitationAnswers = [:], respond: @escaping (ElicitationReply) -> Void) {
            self.form = form
            self.answers = answers
            self.respond = respond
        }

        package let id = UUID()
        package let form: ElicitationForm
        package var answers: ElicitationAnswers = [:]
        package let respond: (ElicitationReply) -> Void
    }

    package var items: [Item] = [] {
        willSet { changes.send() }
        didSet { publishItemChanges(from: oldValue) }
    }
    /// Where `chat.item` and `chat.state` are published for API clients.
    package weak var events: APIEventBus?

    /// Publishes on the event bus, tagged with this chat's agent unless it is agent 1, so a client that watches several agents' chats can
    /// tell whose message changed.
    private func publish(_ kind: APIEventKind, id: String? = nil) {
        events?.publish(kind, id: id, agentId: ownerAgentID == AgentOwner.defaultID ? nil : ownerAgentID)
    }

    /// Publishes `chat.item` with the id of each item that was added or changed. A removal, a reset or a change to many items at once
    /// publishes it without an id, which tells a client to read the transcript again.
    private func publishItemChanges(from old: [Item]) {
        guard let events else { return }
        guard let changed = Self.changedItems(old: old, new: items) else { return publish(.chatItem) }
        for id in changed { publish(.chatItem, id: id.uuidString) }
    }

    /// The ids of added or edited items, or nil when the change is not that: a removal, a reorder, a reset, or more than a few edits.
    package static func changedItems(old: [Item], new: [Item]) -> [UUID]? {
        guard new.count >= old.count else { return old.isEmpty && new.isEmpty ? [] : nil }
        var changed: [UUID] = []
        for index in old.indices {
            guard old[index].id == new[index].id else { return nil }
            if old[index] != new[index] {
                changed.append(new[index].id)
                if changed.count > 8 { return nil }
            }
        }
        return changed + new[old.count...].map(\.id)
    }
    package var workspace: URL? {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    /// Set when the chat opened outside a coding app; the user picks a folder before sending.
    package private(set) var needsWorkspace = false {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    package private(set) var recents: [URL] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    /// The permission mode the agent reported for this chat's session, and every mode it advertises. Both are empty until the session
    /// starts. The chat offers exactly those modes and adds none.
    package private(set) var agentMode: String? {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    package private(set) var agentModes: [AgentMode] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }

    private static func modeKey(_ agent: ACPAgent) -> String { "chatMode.\(agent.id)" }

    /// The mode the user picked for the current agent, kept across new chats, saved threads and restarts. Nil means the agent's own
    /// default, which is the mode the user set up in that agent (Claude Code reads `permissions.defaultMode`).
    package var pickedMode: String? {
        UserDefaults.standard.string(forKey: Self.modeKey(agent))
    }

    /// The user picked one of the agent's modes. Saved per agent, and applied to the open session at once.
    package func setMode(_ id: String) {
        guard agentModes.isEmpty || agentModes.contains(where: { $0.id == id }) else { return }
        if persists { UserDefaults.standard.set(id, forKey: Self.modeKey(agent)) }
        ChatLog.note("\(agent.name): user picked mode \(id)")
        if let acp { Task { await acp.setMode(id) } } else { agentMode = id }
    }

    package func receiveModes(current: String?, modes: [AgentMode]) {
        agentModes = modes
        agentMode = current
    }

    package private(set) var state: State = .idle {
        willSet { changes.send() }
        didSet { if state != oldValue { publish(.chatState) } }
    }
    /// Approvals, forms and the queue change without `state` changing, so each publishes `chat.state` with what changed as the id.
    package private(set) var approvals: [Approval] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "approvals") }
    }
    package private(set) var forms: [PendingForm] = [] {
        willSet { changes.send() }
        didSet {
            publish(.chatState, id: "forms")
            onFormsChanged?()
        }
    }
    /// The agent whose main chat this is. Its threads are the ones `history` lists.
    package let ownerAgentID: String
    package private(set) var history: [ChatThread] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "threads") }
    }
    /// Messages typed while a turn runs. Each keeps the attachments present when it was queued.
    package private(set) var queue: [QueuedMessage] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "queue") }
    }
    /// Everything still going on in the background, and what finished: subagents, shells, monitors, workflows and IronPet jobs.
    package private(set) var background = BackgroundWorkList() {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "background") }
    }
    /// The clock for background rows. Tests set it.
    package var backgroundClock: () -> Date = Date.init
    /// Reads the last lines of a shell's or monitor's output file off the main actor.
    package var outputTail: (String) async -> [String]? = { path in await Task.detached { OutputTail.lines(at: path) }.value }
    /// Stops an IronPet job by its id. The Mac sets it to the job service's stop.
    package var jobStopper: ((String) -> Void)?
    /// Replaces `ACPBackend.stopAsyncTask` in tests.
    package var asyncTaskStopper: ((String) -> Void)?
    /// When each tool call started, for the elapsed time of the one that turns out to be a subagent.
    private var toolStarts: [String: Date] = [:]
    /// What the agent is doing right now, e.g. "Running `npm test`".
    package private(set) var activity: String? {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "status") }
    }
    package private(set) var runStartedAt: Date? {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "status") }
    }
    package private(set) var lastRunDuration: TimeInterval? {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "status") }
    }
    /// Models the agent offered in its last session. Empty hides the picker.
    package private(set) var models: [ChatModel] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    package private(set) var agent: ACPAgent =
        AgentCatalog.agent(id: ChatAgentPreference.resolveID())! {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    /// Installed agents that answer `initialize`. Starts as just the current one until the check finishes.
    package private(set) var agents: [ACPAgent] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    package private(set) var commands: [SlashCommand] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "commands") }
    }
    package func receiveCommands(_ list: [SlashCommand]) {
        commands = list
        if persists { SlashCommand.store(list, for: agent.id) }
    }
    /// nil uses the agent's default model. Stored per agent.
    package var model: String? {
        willSet { changes.send() }
        didSet {
            if let registry { _ = try? registry.update(ownerAgentID, AgentRecordPatch(model: .some(model))) }
            else { UserDefaults.standard.set(model, forKey: "chatModel.\(agent.id)") }
            publish(.chatState, id: "options")
        }
    }
    /// This chat's agent record. Once set, the chat's CLI and model are read from it and written to it, not kept in `UserDefaults`.
    private var registry: AgentRegistry?
    /// What the user calls this chat's agent. Agent 1 is the pet, named in Settings. Another agent has its own name.
    package var agentDisplayName: String {
        if ownerAgentID != AgentOwner.defaultID, let name = registry?.get(ownerAgentID)?.name { return name }
        return ConfigStore.shared.config.pet.name
    }

    /// The agent's standing instructions. They go with the first turn of every new agent session, after the memory notes.
    package private(set) var instructions: String = ""

    /// Starts reading and writing the chat's agent CLI and model on this chat's agent record. The registry needs the database, which opens
    /// after the chat is built, so the app calls this once it is open (after `AgentRegistry.adoptLegacySettings`). Calling it again reads
    /// the record again, which is how a changed CLI, model or instruction reaches a running chat.
    package func attach(registry: AgentRegistry) {
        guard let record = registry.get(ownerAgentID) else { return }
        self.registry = registry
        instructions = record.instructions
        guard let stored = AgentCatalog.agent(id: record.agentCli) else { return }
        if stored != agent {
            agent = stored
            models = Self.cachedModels(for: stored)
            commands = SlashCommand.cached(for: stored.id)
            if !agents.contains(stored) { agents.append(stored) }
        }
        if model != record.model { model = record.model }
    }
    /// Set when an adapter has no runtime: the chat offers a one-time Bun download.
    package private(set) var runtimeOffer: String? {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    package private(set) var installingRuntime = false {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }
    /// Set when the agent asks the user to sign in.
    package private(set) var signInOptions: [AuthMethod] = [] {
        willSet { changes.send() }
        didSet { publish(.chatState, id: "options") }
    }

    package var modelName: String {
        guard let model else { return "Default" }
        return models.first { $0.id == model }?.name ?? model
    }

    /// Called when something needs the user while the chat is hidden.
    package var onAttention: ((String) -> Void)?
    /// A new approval card while the chat is hidden; answered from a notification.
    package var onApprovalNeeded: ((Approval) -> Void)?
    package var onApprovalResolved: ((UUID) -> Void)?
    /// A new form while the chat is hidden: a title and the form's message.
    package var onFormNeeded: ((String, String) -> Void)?
    package var isVisible = false
    /// Reports progress of turns that another client sent (`submit`), with the origin it gave.
    package var onTurn: ((ChatOrigin, TurnEvent) -> Void)?
    /// A form opened, closed or got an answer.
    package var onFormsChanged: (() -> Void)?
    /// Reports the start and end of a turn that an automation sent (`submitFromAutomation`).
    package var onAutomation: ((String, AutomationEvent) -> Void)?
    /// The final reply of an automation's turn, with the automation's id, for Ghost's memory to read as outside text.
    package var onAutomationAnswer: ((String, String) -> Void)?
    /// A turn ended in this thread, so its quiet time starts.
    package var onTurnEnded: ((String) -> Void)?
    /// The chat has nothing running or queued any more, after the reply was read aloud if it is read. The flag is true when the turn
    /// failed or was stopped. The Mac's spoken messages listen again on it.
    package var onSpokenTurnEnded: ((_ failed: Bool) -> Void)?
    /// The user moved on from this thread: a new chat, or another thread opened.
    package var onThreadLeft: ((String) -> Void)?
    private var automationRun: String?
    /// The `quiet` reply of an automation, by id. A turn whose final reply is exactly that text is hidden.
    package var quietReply: (String) -> [String]? = { _ in nil }
    private var turnOrigin: ChatOrigin?

    /// The IronPet thread. It is the first agent session's id and never changes, so memory search hits stay valid.
    package private(set) var threadID: String? {
        didSet { if persists { UserDefaults.standard.set(threadID, forKey: threadKey) } }
    }
    /// The agent session the thread runs on. Differs from `threadID` after a rollover; nil before the first turn and
    /// between a rollover and the first turn of the new session.
    package private(set) var agentSessionID: String?
    /// Sessions the thread left at a rollover, oldest first.
    private var previousSessions: [String] = []
    /// What the next new session's first turn carries after a rollover. Cleared once the new session exists.
    private var pendingHandoff: String?
    /// Set while the old session writes its handoff summary. The chat shows as busy, so messages queue.
    private var rollover: UUID?
    private var rolloverWaiting = false
    private var rolledFrom: (id: String, bytes: Int64)?
    /// The transcript size at which the chat moves to a fresh agent session.
    package var rolloverLimit: () -> Int64 = { Int64(Config.load().config.chat.sessionRolloverMB) * 1_048_576 }
    /// The size of an agent session's transcript: agent id, folder, session id. Nil when it cannot be located.
    package var sessionSize: (String, String, String) -> Int64? = { AgentTranscript.size(agent: $0, workspace: $1, session: $2) }
    /// How long the old session gets to write its summary before the chat builds one from its messages.
    package var handoffTimeout: Duration = .seconds(90)
    /// False for preview sessions, so rendering screenshots neither reads nor overwrites the real chat.
    private let persists: Bool
    /// Where the open thread's id is kept between launches. Agent 1 keeps the key it always had.
    private var threadKey: String { ownerAgentID == AgentOwner.defaultID ? "chatThread" : "chatThread.\(ownerAgentID)" }
    private var acp: ACPBackend?
    /// Ignores events from a turn the user stopped.
    private var turnID: UUID?
    private var lastTurn: ACPTurn?
    /// Replaces the agent turn in tests: receives the turn and the callback that delivers its events.
    package var turnRunner: ((ACPTurn, @escaping (AgentEvent) -> Void) async -> Void)?
    /// Replaces `ACPBackend.steer` in tests. Setting it also turns steering on, as an agent that advertises it would.
    package var steerRunner: ((ACPTurn) async -> ACPBackend.SteerOutcome)?
    /// True while a steered message is being handed to the agent, so they go one at a time and in order.
    private var steering = false
    /// Set when the agent refused a steered message. The rest of this turn's queue waits for the turn to end.
    private var steerFailed = false
    /// Counts `stop()` calls, so a steer that was in flight when the user pressed Stop does not send its message after it.
    private var stops = 0
    /// Senders whose messages went into the running turn. They hear how the turn ended, like the sender that started it.
    private var steeredOrigins: [ChatOrigin] = []
    private var toolItems: [String: UUID] = [:]
    /// A tool row's own summary, before the count of its subagent's tool calls is added.
    private var toolBase: [String: String] = [:]
    /// The tool calls each subagent has made, by the subagent's tool-use id, in the order they started.
    private var subagentCalls: [String: [(id: String, ok: Bool?)]] = [:]
    /// The reply item that late updates extend, so a later result starts its own item.
    private var backgroundReply: UUID?
    /// The reply that was still streaming when a steered message landed below it. Further text of the same turn extends it, so the
    /// reply stays in one bubble above that message. A tool step or a new turn clears it. It stays after the turn ends so the turn's answer can still be found, and text only joins it while a turn runs.
    private var splitReply: UUID?
    /// Decisions made during the current run, so a repeated identical check isn't asked twice.
    /// Reads replies aloud. The Mac passes its speech player; without one nothing is spoken.
    package let speech: SpeechOutput
    private var speechChanges: [ChangeToken] = []
    /// The running turn was sent from the chat, not by another client or an automation, and Speak replies says its reply is
    /// read aloud: the first line of the reply is its spoken summary.
    private var turnSpeaksSummary = false
    /// The running turn was sent by a client that reads the reply aloud itself. Its prompt asks for the summary line, and the
    /// client gets that line through `onSummaryTurn`.
    private var turnReadAloudBySender = false
    /// Tells a client that reads replies aloud how its turn ended: the summary line of the reply, or nil when the reply has none.
    /// Called before `onTurn` reports the same turn as finished, and not for a failed turn.
    package var onSummaryTurn: ((ChatOrigin, String?) -> Void)?
    /// The summary of the running turn has been read, or skipped because the speaker is off or the Mac is quiet.
    private var turnSummarySpoken = false
    /// The summary of the running turn was actually handed to the speaker, not skipped.
    private var turnSummaryRead = false
    /// True once an approval card was shown during the running turn. The user took part, so a quiet reply stays visible.
    private var turnAskedApproval = false
    /// True during a call or a meeting recording, when a reply is not read aloud on its own. Set by `AppDelegate`.
    package var isQuiet: () -> Bool = { false }
    /// The Speak replies setting. The app wires it to the config; tests leave Automatic.
    package var speakRepliesSetting: () -> Config.SpeakReplies = { .automatic }
    /// False for an agent that is not the active one: its replies show as text and are not read aloud on their own. The speaker button
    /// on a reply still works. Set by `AppDelegate`; a chat with no other agent beside it always speaks.
    package var speaksReplies: () -> Bool = { true }

    package nonisolated static let scratchWorkspace = Paths.root.appendingPathComponent("scratch")

    /// `restore` reopens the chat that was open when the app last quit: its thread, folder and backend,
    /// plus the unsent draft and attachments. The picked permission mode is kept per agent, not per chat.
    /// Starts the agent's process and the probes. `AppDelegate` sets the Mac one right after creating the session.
    package var spawner: ProcessSpawner = UnsupportedProcessSpawner()

    package init(restore: Bool = true, speech: SpeechOutput? = nil, agentID: String = AgentOwner.defaultID) {
        ownerAgentID = AgentOwner.id(agentID)
        history = ThreadStore.recent(agent: ownerAgentID)
        self.speech = speech ?? UnsupportedSpeechOutput()
        persists = restore
        recents = (UserDefaults.standard.stringArray(forKey: "recentWorkspaces") ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) && $0 != Self.scratchWorkspace }
        workspace = recents.first
        model = UserDefaults.standard.string(forKey: "chatModel.\(agent.id)")
        models = Self.cachedModels(for: agent)
        commands = SlashCommand.cached(for: agent.id)
        agents = [agent]
        if restore { Task { await refreshAgents() } }
        if restore { restoreLastChat() }
        speechChanges = [self.speech.changes.observe { [weak self] in self?.changes.send() }]
        // Chats of several agents share one speaker, so the first chat (agent 1's) keeps its failure messages.
        if self.speech.onFailure == nil { self.speech.onFailure = { [weak self] message in self?.items.append(Item(kind: .error(message))) } }
    }

    /// Reads a reply aloud, or stops it when it is the one being read.
    package func toggleSpeech(_ item: Item) {
        guard case .assistant(let text) = item.kind else { return }
        if speech.speakingID == item.id { speech.stop() } else { try? speech.speak(text, id: item.id) }
    }

    /// Adds an error line to the transcript, such as a voice note that could not be transcribed. Returns its id.
    @discardableResult
    package func appendNotice(_ message: String) -> UUID {
        let item = Item(kind: .error(message))
        items.append(item)
        return item.id
    }

    package func removeItem(_ id: UUID) { items.removeAll { $0.id == id } }

    private func restoreLastChat() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: threadKey), let thread = ThreadStore.load(id) {
            apply(thread.restoredAfterQuit(), reason: "restore after launch")
        }
    }

    /// Writes the open thread to disk, e.g. when the app quits mid-run.
    package func persistForRelaunch() {
        guard persists else { return }
        saveThread()
    }

    package var mood: PetMood? {
        if !approvals.isEmpty || !forms.isEmpty { return .needsInput }
        switch state {
        case .running: return .working
        case .done: return .done
        case .failed: return .failed
        case .idle: return isVisible ? .listening : nil
        }
    }

    package var isRunning: Bool { state == .running }

    /// Called when the chat opens. The session and folder stay as they are. Only when no folder was ever chosen does
    /// the picker show.
    package func prepareForShow() {
        if state == .done || state == .failed, approvals.isEmpty, forms.isEmpty { state = .idle }
        if workspace == nil { needsWorkspace = true }
    }

    package func use(_ url: URL) {
        let changed = workspace != url
        workspace = url
        needsWorkspace = false
        if url != Self.scratchWorkspace {
            recents = [url] + recents.filter { $0 != url }.prefix(7)
            UserDefaults.standard.set(recents.map(\.path), forKey: "recentWorkspaces")
        }
        if changed { ChatLog.note("workspace changed to \(url.path)") }
        if changed, !items.isEmpty, !isRunning { newChat(reason: "folder picked: \(url.path)") }
    }

    /// For general questions that are not about a project.
    package func useNoProject() {
        try? FileManager.default.createDirectory(at: Self.scratchWorkspace, withIntermediateDirectories: true)
        use(Self.scratchWorkspace)
    }

    package var workspaceLabel: String {
        guard let workspace else { return "Choose a folder" }
        return workspace == Self.scratchWorkspace ? "No project" : workspace.lastPathComponent
    }

    package func setAgent(_ next: ACPAgent) {
        guard next != agent, !isRunning else { return }
        ChatLog.note("agent changed from \(agent.id) to \(next.id)")
        select(next)
        if !items.isEmpty { newChat(reason: "agent changed to \(next.id)") }
    }

    private func select(_ next: ACPAgent) {
        agent = next
        if let registry {
            // The record brings back the model last picked for this CLI.
            let record = try? registry.update(ownerAgentID, AgentRecordPatch(agentCli: next.id))
            model = record?.model
        } else {
            UserDefaults.standard.set(next.id, forKey: ChatAgentPreference.key)
            model = UserDefaults.standard.string(forKey: "chatModel.\(next.id)")
        }
        models = Self.cachedModels(for: next)
        commands = SlashCommand.cached(for: next.id)
        if !agents.contains(next) { agents.append(next) }
    }

    /// Lists the installed agents that speak ACP. The first launch switches to an installed one if the saved choice is missing.
    package func refreshAgents() async {
        // Before `AppDelegate` wires the Mac spawner every probe would fail, and the list would lose the agents that answer by spawning.
        guard spawner.isSupported else { return }
        let found = await ACPProbe.installed(spawner: spawner)
        guard !found.isEmpty else { return }
        agents = found
        if !found.contains(agent), items.isEmpty, !isRunning, let first = found.first { select(first) }
    }

    package static func cachedModels(for agent: ACPAgent) -> [ChatModel] {
        (UserDefaults.standard.array(forKey: "cachedModels.\(agent.id)") as? [[String]] ?? []).compactMap {
            $0.count == 2 ? ChatModel(id: $0[0], name: $0[1]) : nil
        }
    }

    /// Sample conversations for `--render-previews`.
    package enum Preview { case done, approval, markdown, form, rows }

    package func loadPreview(_ preview: Preview) {
        workspace = URL(fileURLWithPath: "/Users/you/code/demo-app")
        needsWorkspace = false
        if preview == .rows {
            // An automation notice above a folded run of commands, to compare the two quiet rows.
            items = [
                Item(kind: .notice("Automation: Task review\nReview the open tasks and report which are blocked.")),
                Item(kind: .tool("Ran `git status`", ok: true)),
                Item(kind: .tool("Ran `npm test`", ok: true)),
                Item(kind: .assistant("Two tasks are blocked on review.")),
            ]
            state = .done
            return
        }
        if preview == .markdown {
            items = [
                Item(kind: .user("how does login refresh the token?")),
                Item(kind: .assistant("""
                    ## Token refresh

                    `login()` stores the session, then **refreshes the token** before it expires:

                    1. Read the expiry from the session
                    2. Schedule `refreshToken()` 60 s early
                       - retries twice on a network error
                    3. Replace the stored token

                    | Step | File |
                    |------|------|
                    | Login | `src/auth/login.ts` |
                    | Refresh | `src/auth/session.ts` |

                    ```ts
                    await refreshToken(session)
                    ```

                    > The test was flaky because step 2 was not awaited.

                    ```mermaid
                    graph LR
                      A[login] --> B[store session] --> C[refresh token]
                    ```
                    """)),
            ]
            state = .done
            return
        }
        items = [
            Item(kind: .user("why is the login test flaky?")),
            Item(kind: .tool("Ran `npm test -- login`", ok: false)),
            Item(kind: .tool("Read src/auth/session.ts", ok: true)),
            Item(kind: .assistant("`refreshToken()` resolves after the test checks the session, so it fails whenever the mock server is slow. Awaiting it in `login()` fixes it. Want me to make the change?")),
            Item(kind: .user("yes please")),
        ]
        switch preview {
        case .approval:
            items.append(Item(kind: .tool("Edited src/auth/session.ts", ok: true)))
            state = .running
            activity = "Waiting for you"
            runStartedAt = Date().addingTimeInterval(-9)
            approvals = [Approval(title: "Run this command?", detail: "npm test -- login --runInBand", responders: [])]
        case .done:
            items.append(Item(kind: .tool("Edited src/auth/session.ts", ok: true)))
            items.append(Item(kind: .tool("Ran `npm test -- login`", ok: true)))
            items.append(Item(kind: .assistant("Done! `login()` now waits for the token refresh, and the test passed 20 runs in a row.")))
            state = .done
            lastRunDuration = 14
        case .markdown, .rows:
            break
        case .form:
            state = .running
            activity = "Waiting for you"
            runStartedAt = Date().addingTimeInterval(-9)
            if let form = ElicitationForm.parse(Self.sampleForm) {
                forms = [PendingForm(form: form, answers: ["question_0": .one("Swift Testing"), "question_1": .many(["lint"])], respond: { _ in })]
            }
        }
    }

    /// One moment of a sample conversation, for the `--render-videos` clips: running while `activity` or `approval` is set,
    /// otherwise done, or idle with no items.
    package func showPreview(_ items: [Item], activity: String? = nil, approval: (title: String, detail: String)? = nil, ranFor: TimeInterval? = nil) {
        workspace = URL(fileURLWithPath: "/Users/you/code/demo-app")
        needsWorkspace = false
        self.items = items
        let running = activity != nil || approval != nil
        state = running ? .running : items.isEmpty ? .idle : .done
        self.activity = approval == nil ? activity : "Waiting for you"
        runStartedAt = running ? Date().addingTimeInterval(-(ranFor ?? 4)) : nil
        lastRunDuration = running ? nil : ranFor
        approvals = approval.map { [Approval(title: $0.title, detail: $0.detail, responders: [])] } ?? []
    }

    /// A reply with every text block, for the markdown previews.
    package static let sampleMarkdown = """
    ## Plan
    The first paragraph has `code`, **bold**, a [link](https://example.com) and the path /etc/hosts, and it runs long enough to wrap onto a second line.

    - First item is long enough to wrap onto a second line at the narrow column width, so the hanging indent shows
      - Nested item
        - Deeper nested item
    - [ ] Open task item
    - [x] Done task item

    1. One
    2. Two is long enough to wrap onto a second line at the narrow column width, so the hanging indent shows
    3. Three

    > A quoted line that also wraps around when the column is narrow enough to need it, with `code` inside.

    ```swift
    let answer = 42
    ```

    Closing paragraph after the code block.
    """

    private static let sampleForm: JSON = [
        "mode": "form", "message": "Please answer the following questions.",
        "requestedSchema": ["type": "object", "properties": [
            "question_0": ["type": "string", "title": "Test runner", "description": "Which test runner should the new tests use?",
                           "oneOf": [["const": "XCTest", "title": "XCTest", "description": "Already used by every test in this repo"],
                                     ["const": "Swift Testing", "title": "Swift Testing", "description": "Newer macros, needs Xcode 16"]]],
            "question_0_custom": ["type": "string", "title": "Other", "description": "Type your own answer, or add a note to the option you chose above (optional)."],
            "question_1": ["type": "array", "title": "Checks", "description": "Which checks should run before the commit?",
                           "items": ["anyOf": [["const": "lint", "title": "Lint"], ["const": "build", "title": "Build", "description": "swift build"],
                                               ["const": "test", "title": "Tests", "description": "swift test, about two minutes"]]]],
            "question_1_custom": ["type": "string", "title": "Other", "description": "Type your own answer to add to your selection above (optional)."],
        ] as JSON],
    ]

    /// Most characters of the original that reach the agent.
    package static let replyLimit = 4000

    private static let replyTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// The prompt the agent receives for a reply: the original quoted in full, then the user's text.
    package static func replyPrompt(_ reply: Reply, text: String) -> String {
        var original = reply.text
        var note = ""
        if original.count > replyLimit {
            note = "\n[The original was cut here. It is \(original.count) characters long.]"
            original = String(original.prefix(replyLimit))
        }
        let owner = reply.fromUser ?? (reply.sender == "You") ? "your own" : "\(reply.sender)'s"
        let when = reply.date.map { " from \(replyTime.string(from: $0))" } ?? ""
        let quoted = (original + note).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let lead = reply.selection == true ? "About this part of" : "Replying to"
        return "> \(lead) \(owner) message\(when):\n\(quoted)\n\n\(text)"
    }

    /// What the agent receives: optional front-app selection, then an optional reply quote, then the user's text.
    package static func outgoingPrompt(text: String, reply: Reply?, selection: FrontSelection?) -> String {
        let withReply = reply.map { replyPrompt($0, text: text) } ?? text
        return selection.map { FrontSelection.prompt($0, text: withReply) } ?? withReply
    }

    /// The picked permission mode is not touched: it is kept per agent, not per chat.
    package func newChat(reason: String = "new chat requested") {
        ChatLog.note("chat cleared (\(items.count) items, thread \(threadID ?? "none")): \(reason)")
        if let threadID { onThreadLeft?(threadID) }
        stop()
        shutdownAgent()
        items = []
        threadID = nil
        agentSessionID = nil
        previousSessions = []
        pendingHandoff = nil
        jobMessages = []
        background.dropChatWork()
        toolStarts = [:]
        subagentCalls = [:]
        state = .idle
        lastRunDuration = nil
    }

    package func open(_ thread: ChatThread) {
        if let threadID, threadID != thread.id { onThreadLeft?(threadID) }
        stop()
        shutdownAgent()
        apply(thread, reason: "opened from history")
    }

    private func apply(_ thread: ChatThread, reason: String) {
        ChatLog.note("thread \(thread.id) loaded (\(thread.items.count) items), replacing thread \(threadID ?? "none"): \(reason)")
        if let saved = AgentCatalog.agent(id: thread.agent), saved != agent { select(saved) }
        items = thread.items
        threadID = thread.id
        agentSessionID = thread.activeSession
        previousSessions = thread.previousSessions ?? []
        pendingHandoff = thread.handoff
        jobMessages = []
        state = .idle
        let url = URL(fileURLWithPath: thread.workspace)
        workspace = url
        needsWorkspace = false
        if url != Self.scratchWorkspace { recents = [url] + recents.filter { $0 != url }.prefix(7) }
    }

    private func saveThread() {
        guard let threadID, let workspace else { return }
        let firstPrompt = items.lazy.compactMap { item -> String? in
            if case .user(let text) = item.kind { return text } else { return nil }
        }.first ?? "Chat"
        let title = firstPrompt.count > 60 ? String(firstPrompt.prefix(57)) + "…" : firstPrompt
        var thread = ChatThread(id: threadID, title: title, workspace: workspace.path, updatedAt: Date(), items: items, agent: agent.id,
                                agentId: ownerAgentID)
        // Continuing an automation's thread keeps it marked as one, and keeps its run count.
        if let earlier = ThreadStore.load(threadID), earlier.automation != nil {
            thread.title = earlier.title
            thread.automation = earlier.automation
            thread.automationName = earlier.automationName
            thread.runs = earlier.runs
        }
        if let earlier = ThreadStore.load(threadID), earlier.job != nil || earlier.voice == true {
            thread.title = earlier.title
            thread.job = earlier.job
            thread.voice = earlier.voice
        }
        thread.session = agentSessionID == threadID ? nil : agentSessionID
        thread.previousSessions = previousSessions.isEmpty ? nil : previousSessions
        thread.handoff = pendingHandoff
        ThreadStore.save(thread)
        history = ThreadStore.recent(agent: ownerAgentID)
    }

    /// Reloads the thread list after something else saved a thread, such as an automation run.
    package func refreshHistory() { history = ThreadStore.recent(agent: ownerAgentID) }

    /// A background job saved `thread`. When it is the one on screen and no turn of the chat's own is running, the
    /// transcript shows the job's new steps.
    package func threadSaved(_ thread: ChatThread) {
        refreshHistory()
        guard thread.id == threadID, !isRunning else { return }
        let sent = Set(thread.items.compactMap { item -> String? in
            if case .user(let text) = item.kind { return text } else { return nil }
        })
        // Messages typed here that the job has not started on yet are not in its transcript.
        jobMessages.removeAll { sent.contains($0.sent) }
        items = thread.items + jobMessages.map(\.item)
    }

    /// What a message typed in a job's thread sends to the job.
    package static func jobMessage(_ text: String, reply: Reply?, files: [URL], selection: FrontSelection? = nil) -> String {
        var message = outgoingPrompt(text: text, reply: reply, selection: selection)
        if !files.isEmpty { message += (message.isEmpty ? "" : "\n\n") + "Attached files:\n" + files.map { "- \($0.path)" }.joined(separator: "\n") }
        return message
    }

    /// Messages typed into the open job thread that are waiting for the job's current turn to end.
    private var jobMessages: [(item: Item, sent: String)] = []

    /// Takes a message typed in a thread whose background job is still running (thread id, text). Returns false when no
    /// job runs there, so the chat sends it itself.
    package var jobFollowUp: ((String, String) -> Bool)?
    /// Whether a reply to a message sent from the chat is read aloud: the Speak replies setting against how the message was
    /// sent, and the speaker being on. Such a turn tells the agent to start its reply with a summary.
    /// A turn is running whose reply is read aloud, so a job it starts has its updates said.
    package var readsReply: Bool { isRunning && turnSpeaksSummary }

    private func replySpoken(afterSpokenMessage spoken: Bool) -> Bool {
        speech.isEnabled() && speakRepliesSetting().speaks(afterSpokenMessage: spoken)
    }

    /// What happened to a message typed on this Mac.
    package enum LocalSend: String, Codable { case ignored, sent, queued, toJob, needsFolder }

    /// A message typed on this Mac. A running turn queues it, a running background job in this thread takes it, and with no
    /// folder chosen it is refused so the picker can show. The caller keeps the draft until the answer says it was taken.
    package func submitLocal(_ text: String, files: [URL], reply: Reply?, selection: FrontSelection? = nil, spoken: Bool = false) -> LocalSend {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !files.isEmpty else { return .ignored }
        speech.stop()
        // A second process on the job's session would race it, so everything typed here goes to the job: a reply as its
        // quoted prompt, attachments as their paths.
        let message = Self.jobMessage(prompt, reply: reply, files: files, selection: selection)
        if !isRunning, let threadID, jobFollowUp?(threadID, message) == true {
            let item = Item(kind: .user(prompt.isEmpty ? "Attached files" : prompt), origin: Self.jobOrigin, reply: reply)
            items.append(item)
            jobMessages.append((item, message))
            return .toJob
        }
        if isRunning {
            queue.append(QueuedMessage(text: prompt, attachments: files, reply: reply, selection: selection, spoken: spoken))
            steerNext()
            return .queued
        }
        return start(prompt: prompt, shots: files, reply: reply, selection: selection, spoken: spoken) ? .sent : .needsFolder
    }

    /// Starts a turn. Returns false, without sending, when no folder is chosen or the hooks are missing.
    @discardableResult
    private func start(prompt: String, shots: [URL], from client: ChatOrigin? = nil, reply: Reply? = nil,
                       selection: FrontSelection? = nil, automation: String? = nil, silent: Bool = false, spoken: Bool = false,
                       readAloudBySender: Bool = false) -> Bool {
        var prompt = prompt
        let pendingMeta = items.flatMap { $0.meta != nil && $0.metaSent != true ? $0.meta! : [] }
        // A notice turn with nothing left to deliver (a message went first and took it) has nothing to do.
        if silent, pendingMeta.isEmpty { return true }
        let background = client != nil || automation != nil || silent
        if background, workspace == nil {
            // No chat has a folder yet. The no-project folder is what a chat with no code context uses.
            try? FileManager.default.createDirectory(at: Self.scratchWorkspace, withIntermediateDirectories: true)
            workspace = Self.scratchWorkspace
            needsWorkspace = false
        }
        // A message from another client uses the chat as it is, so it does not wait for a folder pick.
        guard background || !needsWorkspace, let workspace else {
            needsWorkspace = true
            return false
        }
        if background, state == .done || state == .failed { state = .idle }
        if prompt.isEmpty, !silent { prompt = client == nil ? "Help me with what's on my screen." : "Help me with the attached file." }
        let origin = client?.client ?? (automation != nil ? Self.automationOrigin : spoken ? Self.voiceOrigin : nil)
        splitReply = nil
        if !silent {
            items += shots.map { Item(kind: .screenshot($0.path), origin: origin) }
            items.append(Item(kind: .user(prompt), origin: origin, reply: reply, selection: selection))
        }
        // The first turn of every new agent session carries the memory notes, including the one after a rollover. Building them reads the
        // memory store and the config from disk. A client's message waits for its ack on this actor, so for a client the build moves
        // after the ack (see `run`). A message typed on the Mac builds it here, as before.
        let handoff = pendingHandoff
        let buildPreamble: (() -> String?)? = agentSessionID == nil ? {
            var built = Self.preambleBuilder(workspace, prompt)
            if let handoff, let notes = built { built = SessionHandoff.insert(handoff, into: notes) }
            return Self.withInstructions(self.instructions, built)
        } : nil
        var preamble: String?
        if client == nil { preamble = buildPreamble?() }
        turnOrigin = client
        turnSpeaksSummary = client == nil && automation == nil && !silent && replySpoken(afterSpokenMessage: spoken)
        turnReadAloudBySender = client != nil && readAloudBySender && automation == nil && !silent
        turnSummarySpoken = false
        turnSummaryRead = false
        turnAskedApproval = false
        if let client { onTurn?(client, .started) }
        automationRun = automation
        if let automation { onAutomation?(automation, .started) }
        // Pending notices go with this turn once. What the user, a client or a tool wrote cannot contain a genuine meta tag.
        for index in items.indices where items[index].meta != nil && items[index].metaSent != true { items[index].metaSent = true }
        let sent = MetaTag.escape(Self.outgoingPrompt(text: prompt, reply: reply, selection: selection))
        var text = silent ? MetaTag.triggerLead : SpokenSummary.prompt(sent, on: turnSpeaksSummary || turnReadAloudBySender)
        if !pendingMeta.isEmpty { text += "\n\n" + MetaTag.block(pendingMeta) }
        run(ACPTurn(prompt: text, preamble: preamble, workspace: workspace, resume: agentSessionID, model: model,
                    images: shots.filter(FolderFileIntake.isImageFile), files: shots.filter { !FolderFileIntake.isImageFile($0) }),
            laterPreamble: client == nil ? nil : buildPreamble)
        return true
    }

    /// The agent's standing instructions after the memory notes. Empty instructions change nothing, so agent 1 sends what it always did.
    package nonisolated static func withInstructions(_ instructions: String, _ preamble: String?) -> String? {
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return preamble }
        let block = "<agent_instructions>\n\(text)\n</agent_instructions>"
        guard let preamble, !preamble.isEmpty else { return block }
        return preamble + "\n\n" + block
    }

    /// Builds the memory notes for a new agent session. A test replaces it to make the build slow.
    package static var preambleBuilder: (URL, String) -> String? = { workspace, firstMessage in
        MemoryPreamble.build(store: EntityMemoryStore.shared, workspace: workspace, firstMessage: firstMessage)
    }

    /// Starts the turn. With `laterPreamble`, the turn is marked running at once but the notes are built and the agent started after one
    /// yield, so a caller that is waiting on this actor (the phone's ack) is not held up by the disk reads.
    private func run(_ turn: ACPTurn, laterPreamble: (() -> String?)? = nil) {
        lastTurn = turn
        runtimeOffer = nil
        signInOptions = []
        state = .running
        activity = "Thinking"
        runStartedAt = Date()
        lastRunDuration = nil
        let id = UUID()
        turnID = id
        if let laterPreamble {
            Task { [weak self] in
                await Task.yield()
                guard let self, self.turnID == id else { return }
                var turn = turn
                turn.preamble = laterPreamble()
                self.launch(turn, id: id)
            }
            return
        }
        launch(turn, id: id)
    }

    private func launch(_ turn: ACPTurn, id: UUID) {
        lastTurn = turn
        if let turnRunner {
            Task { [weak self] in await turnRunner(turn) { event in self?.handle(event, turn: id) } }
            return
        }
        if agent.id == "cursor", Config.load().config.integrations.shareMCPSignIns { MCPAuthSharing.prepare(workspace: turn.workspace) }
        let backend = acp?.agent == agent ? acp! : makeBackend()
        Task { [weak self] in
            await backend.runTurn(turn) { event in self?.handle(event, turn: id) }
        }
    }

    package func removeQueued(_ id: UUID) {
        if let automation = queue.first(where: { $0.id == id })?.automation { onAutomation?(automation, .cancelled("Removed from the queue.")) }
        queue.removeAll { $0.id == id }
    }

    /// Hands queued messages back to the Mac's draft (`takeRestoredDraft`), so nothing is lost. Messages that came
    /// from another client go back to it as a failure instead: they are not the Mac user's draft.
    /// Queued Mac messages that were cancelled before they started, for the draft to take back.
    package struct RestoredDraft: Equatable {
        package init(text: String, attachments: [URL], reply: Reply? = nil, selection: FrontSelection? = nil) {
            self.text = text
            self.attachments = attachments
            self.reply = reply
            self.selection = selection
        }

        package var text: String
        package var attachments: [URL]
        package var reply: Reply?
        package var selection: FrontSelection?
    }

    package private(set) var restoredDraft: RestoredDraft?

    /// The messages `stop` or a failed start handed back, once.
    package func takeRestoredDraft() -> RestoredDraft? {
        defer { restoredDraft = nil }
        return restoredDraft
    }

    private func restoreQueue(reason: String = "Cancelled on the Mac before it started.") {
        for message in queue { if let origin = message.origin { onTurn?(origin, .failed(reason)) } }
        queue.removeAll { $0.origin != nil }
        for message in queue { if let id = message.automation { onAutomation?(id, .cancelled(reason)) } }
        queue.removeAll { $0.automation != nil }
        // A notice turn has no text for the draft. The notice stays pending and goes with the next turn.
        queue.removeAll { $0.notice }
        guard !queue.isEmpty else { return }
        let text = queue.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let earlier = restoredDraft
        restoredDraft = RestoredDraft(text: [earlier?.text, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                      attachments: (earlier?.attachments ?? []) + queue.flatMap(\.attachments),
                                      reply: earlier?.reply ?? queue.compactMap(\.reply).first,
                                      selection: earlier?.selection ?? queue.compactMap(\.selection).first)
        queue = []
        publish(.chatState, id: "draft")
    }

    /// True when the running turn takes a message typed now: the agent advertised steering.
    private var canSteer: Bool {
        if turnRunner != nil { return steerRunner != nil }
        return acp?.canSteer == true
    }

    /// True while queued messages wait for the user to answer an approval or a form. The agent would hold a steered message
    /// until then, and an interrupting one would cancel the card, so ironpet sends it after the answer.
    package var queueWaitsForAnswer: Bool {
        isRunning && canSteer && !steerFailed && (!approvals.isEmpty || !forms.isEmpty) && queue.contains { $0.steerable }
    }

    /// Hands the oldest steerable queued message to the running turn, then the next, in order. Does nothing for an agent that
    /// did not advertise steering, or while an approval or form is open. The row becomes a normal sent message once the agent has it.
    private func steerNext() {
        guard !steering, isRunning, canSteer, !steerFailed, approvals.isEmpty, forms.isEmpty,
              let message = queue.first(where: \.steerable) else { return }
        steering = true
        let generation = stops
        queue.removeAll { $0.id == message.id }
        let turn = steerTurn(message)
        Task { [weak self] in
            let outcome: ACPBackend.SteerOutcome
            if let run = self?.steerRunner { outcome = await run(turn) } else { outcome = await self?.acp?.steer(turn) ?? .notRunning }
            self?.steered(message, outcome: outcome, generation: generation)
        }
    }

    private static func displayText(_ message: QueuedMessage) -> String {
        message.text.isEmpty ? (message.origin == nil ? "Help me with what's on my screen." : "Help me with the attached file.") : message.text
    }

    private func steerTurn(_ message: QueuedMessage) -> ACPTurn {
        let prompt = Self.displayText(message)
        let sent = MetaTag.escape(Self.outgoingPrompt(text: prompt, reply: message.reply, selection: message.selection))
        return ACPTurn(prompt: SpokenSummary.prompt(sent, on: message.origin == nil && message.automation == nil && replySpoken(afterSpokenMessage: message.spoken)),
                       preamble: nil, workspace: workspace ?? Self.scratchWorkspace,
                       resume: agentSessionID, model: model,
                       images: message.attachments.filter(FolderFileIntake.isImageFile), files: message.attachments.filter { !FolderFileIntake.isImageFile($0) })
    }

    private func steered(_ message: QueuedMessage, outcome: ACPBackend.SteerOutcome, generation: Int) {
        steering = false
        switch outcome {
        case .delivered:
            let origin = message.origin?.client ?? (message.spoken ? Self.voiceOrigin : nil)
            if isRunning, case .assistant = items.last?.kind { splitReply = items.last?.id }
            items += message.attachments.map { Item(kind: .screenshot($0.path), origin: origin) }
            let prompt = Self.displayText(message)
            items.append(Item(kind: .user(prompt), origin: origin, reply: message.reply, selection: message.selection))
            if let sender = message.origin, stops != generation {
                // Stop came while the message was on its way. Nothing is left to report the turn's end to this sender.
                onTurn?(sender, .failed("Stopped on the Mac."))
            } else if let sender = message.origin {
                if turnOrigin == nil { turnOrigin = sender } else if turnOrigin != sender, !steeredOrigins.contains(sender) { steeredOrigins.append(sender) }
                if turnOrigin == sender { onTurn?(sender, .started) }
            }
            if isRunning { activity = "Thinking" }
        case .notRunning, .failed:
            if case .failed(let reason) = outcome { steerFailed = true; ChatLog.note("steering failed: \(reason)") }
            queue.insert(message, at: 0)
            if stops != generation {
                restoreQueue()
            } else if !isRunning {
                // The turn ended while the message was on its way. Its end found a queue without it.
                sendNextQueued()
            }
        }
        // A message that found no running turn waits for the turn's end, so only a delivery moves on to the next one.
        if case .delivered = outcome { steerNext() }
    }

    /// Sends the oldest queued message through the normal path.
    private func sendNextQueued() {
        guard let next = queue.first else { return }
        if start(prompt: next.text, shots: next.attachments, from: next.origin, reply: next.reply, selection: next.selection,
                 automation: next.automation, silent: next.notice, spoken: next.spoken,
                 readAloudBySender: next.readAloudBySender) {
            queue.removeFirst()
        } else {
            restoreQueue()
        }
    }

    /// A message from another client (Telegram, a remote app). It goes into the chat that is open now, the same way typed
    /// text does, and never changes the chat's thread or folder. A busy agent queues it with the Mac's own queue until the
    /// turn ends. `files` are shown and sent like Mac attachments, without touching the draft the user may be composing.
    /// `onTurn` tells the sender how the turn goes.
    /// With `readAloud`, the sender reads the reply aloud: the turn asks the agent for a summary line first and `onSummaryTurn` hands
    /// that line to the sender.
    package func submit(_ text: String, from origin: ChatOrigin, files: [URL] = [], reply: Reply? = nil, readAloud: Bool = false) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !files.isEmpty else { return }
        guard !isRunning else {
            queue.append(QueuedMessage(text: prompt, attachments: files, origin: origin, reply: reply, readAloudBySender: readAloud))
            onTurn?(origin, .queued)
            steerNext()
            return
        }
        start(prompt: prompt, shots: files, from: origin, reply: reply, readAloudBySender: readAloud)
    }

    /// A prompt from an automation. It goes into the chat that is open now, in the current thread and folder, and
    /// waits in the queue behind a running turn. The user's draft and attachments stay as they are. Without a folder
    /// it uses the no-project folder instead of asking. Returns false when this automation's earlier message is still
    /// queued or running, or the message could not start.
    @discardableResult
    package func submitFromAutomation(_ text: String, automation: String) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !hasAutomationRun(automation) else { return false }
        guard !isRunning else {
            queue.append(QueuedMessage(text: prompt, attachments: [], automation: automation))
            return true
        }
        return start(prompt: prompt, shots: [], automation: automation)
    }

    /// Posts a system notice into the chat. It is a message with metadata, never a user message. `text` goes to the agent
    /// with the next turn, once, in an `<ironpet-meta>` block. A non-nil `title` also shows one line in the transcript, with
    /// `text` shown when expanded. With no title the notice draws nothing. A newer unsent notice with the same `kind`
    /// replaces the older one. `triggersTurn` starts a turn on the notice, behind the running turn if there is one.
    package func postSystemNotice(kind: String, text: String, title: String?, triggersTurn: Bool) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        items.removeAll { $0.metaSent != true && $0.meta?.contains { $0.source == kind } == true }
        let visible = title.map { $0.components(separatedBy: .newlines).joined(separator: " ") + "\n\n" + body } ?? ""
        items.append(Item(kind: .notice(visible), origin: nil, meta: [ItemMeta(source: kind, text: body)]))
        guard triggersTurn else { return }
        if isRunning {
            if !queue.contains(where: \.notice) { queue.append(QueuedMessage(text: "", attachments: [], notice: true)) }
        } else {
            start(prompt: "", shots: [], silent: true)
        }
    }

    /// True while a message from this automation is queued or its turn is running.
    package func hasAutomationRun(_ id: String) -> Bool {
        automationRun == id || queue.contains { $0.automation == id }
    }

    /// Tells the automation how its turn ended. Called before the next queued message starts.
    private func finishAutomationTurn(error: String?, noChange: Bool = false) {
        guard let id = automationRun else { return }
        automationRun = nil
        if error == nil, !noChange, let answer = lastAnswer() { onAutomationAnswer?(id, answer) }
        onAutomation?(id, error.map { .failed($0) } ?? (noChange ? .noChange : .finished))
    }

    /// Removes an automation's whole turn from the transcript when its final reply is exactly its `quiet` text. Tool
    /// calls do not matter, since a check runs tools before it finds nothing to report. The turn stays when the agent
    /// wrote any other text, asked for an approval or a form. A message the user typed waits in the queue, so it is never in the removed range. Returns true when it removed the turn.
    private func hideQuietTurn() -> Bool {
        guard let id = automationRun, let replies = quietReply(id), !replies.isEmpty,
              !turnAskedApproval,
              let start = items.lastIndex(where: { if case .user = $0.kind { return true } else { return false } }),
              items[start].origin == Self.automationOrigin,
              let quiet = lastAnswer()?.trimmingCharacters(in: .whitespacesAndNewlines), replies.contains(quiet) else { return false }
        let rest = items[(start + 1)...]
        let onlyQuiet = rest.allSatisfy { item in
            switch item.kind {
            case .tool: return true
            case .assistant(let text):
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty || t == quiet
            default: return false
            }
        }
        guard onlyQuiet else { return false }
        items.removeSubrange(start...)
        return true
    }

    package func hasPendingApproval(_ id: UUID) -> Bool { approvals.contains { $0.id == id } }

    /// Messages waiting for the agent, not counting automations'.
    package var userQueueCount: Int { queue.filter { $0.automation == nil && !$0.notice }.count }

    /// Forgets a sender's queued messages and the answer it was waiting for.
    package func cancel(from origin: ChatOrigin) {
        queue.removeAll { $0.origin == origin }
        if turnOrigin == origin { turnOrigin = nil }
    }

    /// Tells the sender how its turn ended. Called before the next queued message starts, which replaces `turnOrigin`.
    private func finishTurn(error: String?, noChange: Bool = false) {
        finishAutomationTurn(error: error, noChange: noChange)
        let origins = ([turnOrigin].compactMap { $0 }) + steeredOrigins
        turnOrigin = nil
        steeredOrigins = []
        steerFailed = false
        let answer = error == nil ? lastAnswer() : nil
        if turnReadAloudBySender, error == nil, let origin = origins.first {
            let reply = firstAnswerItem().flatMap { item -> String? in
                if case .assistant(let text) = item.kind { return SpokenSummary.summary(in: text, final: true) } else { return nil }
            }
            onSummaryTurn?(origin, reply)
        }
        turnReadAloudBySender = false
        for origin in origins {
            if let error { onTurn?(origin, .failed(error)) } else { onTurn?(origin, .finished(answer)) }
        }
    }

    /// The first assistant message with text after the newest user message. A reply that asked for a summary starts with it.
    private func firstAnswerItem() -> Item? {
        guard let start = items.lastIndex(where: { if case .user = $0.kind { return true } else { return false } }) else { return nil }
        return items[(start + 1)...].first { item in
            if case .assistant(let text) = item.kind { return !text.allSatisfy(\.isWhitespace) }
            return false
        }
    }

    /// The last assistant message after the newest user message.
    private func lastAnswer() -> String? {
        guard let item = lastAnswerItem(), case .assistant(let text) = item.kind else { return nil }
        return text
    }

    private func lastAnswerItem() -> Item? {
        guard let start = items.lastIndex(where: { if case .user = $0.kind { return true } else { return false } }) else { return nil }
        let answer = items[start...].last { item in
            if case .assistant(let text) = item.kind { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
        // A reply that kept growing above a steered message is the answer when nothing came after that message.
        if answer == nil, let id = splitReply, let item = items.first(where: { $0.id == id }),
           case .assistant(let text) = item.kind, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return item }
        return answer
    }

    private func makeBackend() -> ACPBackend {
        if acp != nil { ChatLog.note("agent backend replaced: \(agent.id), thread \(threadID ?? "none") kept") }
        acp?.shutdown()
        let backend = ACPBackend(agent: agent, spawner: spawner)
        backend.usageFeature = .chat
        backend.onPermission = { [weak self] call, respond in self?.handlePermission(call, respond: respond) }
        backend.onElicitation = { [weak self] form, respond in self?.handleElicitation(form, respond: respond) }
        backend.onBackground = { [weak self] event in self?.handleBackground(event) }
        backend.onPromptSent = { [weak self] in self?.steerNext() }
        backend.onUnexpectedExit = { [weak self] in
            // An idle agent that exits is simply started again by the next message. Only a process that dies in a turn is a crash.
            guard let self, self.isRunning else { return }
            self.onAgentCrash?()
        }
        backend.onModes = { [weak self] current, modes in self?.receiveModes(current: current, modes: modes) }
        backend.preferredMode = pickedMode
        agentModes = []
        agentMode = nil
        acp = backend
        return backend
    }

    private func shutdownAgent() {
        acp?.shutdown()
        acp = nil
    }

    /// For the test endpoints: which process and session the chat is using.
    package var processID: Int32? { acp?.processID }
    package var sessionID: String? { acp?.sessionID ?? agentSessionID }
    package var activeModel: String? { acp?.activeModel }

    package func stop() {
        stops += 1
        rollover = nil
        steerFailed = false
        let steered = steeredOrigins
        steeredOrigins = []
        for origin in steered { onTurn?(origin, .failed("Stopped on the Mac.")) }
        restoreQueue()
        speech.stop()
        turnSpeaksSummary = false
        turnID = nil
        onSpokenTurnEnded?(true)
        acp?.cancel()
        for approval in approvals {
            approval.respond(.deny("Stopped in ironpet"))
            onApprovalResolved?(approval.id)
            if let origin = turnOrigin { onTurn?(origin, .approvalDecided(id: approval.id, outcome: .ended)) }
        }
        approvals = []
        cancelForms()
        activity = nil
        runStartedAt = nil
        if state == .running { state = .idle }
        if let id = automationRun {
            automationRun = nil
            onAutomation?(id, .cancelled("Stopped on the Mac."))
        }
        if let origin = turnOrigin {
            turnOrigin = nil
            onTurn?(origin, .failed("Stopped on the Mac."))
        }
    }

    /// The agent's process ended while a turn ran. The supervisor restarts it with a delay.
    package var onAgentCrash: (() -> Void)?

    /// Stops the agent's process and leaves the chat as it is. The next message starts a new one.
    package func stopAgentProcess() {
        shutdownAgent()
    }

    /// Stops the agent process for good, e.g. when the app quits.
    package func shutdown() {
        stop()
        shutdownAgent()
    }

    package func decide(_ approval: Approval, allow: Bool) {
        decide(id: approval.id, allow: allow)
    }

    /// Allow or deny from a client that has no option buttons (Telegram, the phone): the agent's once-only option of that kind, or
    /// its first one of that kind.
    package func decide(id: UUID, allow: Bool) {
        guard let current = approvals.first(where: { $0.id == id }) else { return }
        let prefix = allow ? "allow" : "reject"
        let option = current.options.first { $0.kind == prefix + "_once" } ?? current.options.first { $0.kind.hasPrefix(prefix) }
        finish(current, option.map(ApprovalDecision.choose) ?? (allow ? .allow : .deny()), allowed: allow)
    }

    /// The user chose one of the options the agent offered.
    package func decide(id: UUID, optionID: String) {
        guard let current = approvals.first(where: { $0.id == id }), let option = current.options.first(where: { $0.id == optionID }) else { return }
        finish(current, .choose(option), allowed: option.allows)
    }

    private func finish(_ current: Approval, _ decision: ApprovalDecision, allowed: Bool) {
        approvals.removeAll { $0.id == current.id }
        current.respond(decision)
        onApprovalResolved?(current.id)
        if let origin = turnOrigin { onTurn?(origin, .approvalDecided(id: current.id, outcome: allowed ? .allowed : .denied)) }
        steerNext()
        if rolloverWaiting { rolloverIfDue() }
    }

    /// Shows the agent's `elicitation/create` form as a card. The reply goes out when the user submits or skips.
    package func handleElicitation(_ form: ElicitationForm, respond: @escaping (ElicitationReply) -> Void) {
        if rollover != nil { return respond(.cancel) }
        let pending = PendingForm(form: form, respond: respond)
        forms.append(pending)
        if !isVisible {
            onFormNeeded?("\(agentDisplayName) has a question for you", String(form.message.prefix(240)))
        }
    }

    package func setAnswer(form id: UUID, field: String, _ value: ElicitationValue?) {
        guard let index = forms.firstIndex(where: { $0.id == id }) else { return }
        forms[index].answers[field] = value
    }

    package func submitForm(_ id: UUID) {
        guard let pending = forms.first(where: { $0.id == id }), pending.form.canSubmit(pending.answers) else { return }
        finishForm(pending, reply: .accept(pending.form.content(pending.answers)),
                   record: ElicitationRecord(message: pending.form.message, skipped: false, lines: pending.form.lines(pending.answers)))
    }

    package func skipForm(_ id: UUID) {
        guard let pending = forms.first(where: { $0.id == id }) else { return }
        finishForm(pending, reply: .decline, record: ElicitationRecord(message: pending.form.message, skipped: true, lines: []))
    }

    private func finishForm(_ pending: PendingForm, reply: ElicitationReply, record: ElicitationRecord) {
        forms.removeAll { $0.id == pending.id }
        items.append(Item(kind: .form(record)))
        pending.respond(reply)
        steerNext()
        if rolloverWaiting { rolloverIfDue() }
    }

    /// The turn stopped or ended with forms open. The agent aborts the tool call that asked.
    private func cancelForms() {
        let open = forms
        forms = []
        open.forEach { $0.respond(.cancel) }
    }

    /// Shows the agent's `session/request_permission` as a card with the options the agent offered. ironpet never answers one
    /// itself and never drops one: the agent's mode decides what it asks, and every request that arrives waits for the user.
    package func handlePermission(_ call: ACPToolCall, respond: @escaping (ApprovalDecision) -> Void) {
        if rollover != nil { return respond(.deny("IronPet is writing a session summary and needs no tools")) }
        let card = ApprovalRules.card(for: call)
        ask(title: card.title, detail: card.detail, options: call.permissionOptions, respond: respond)
    }

    package func retryAfterFix() {
        guard let turn = lastTurn, !isRunning else { return }
        items.removeAll { if case .error = $0.kind { return true } else { return false } }
        run(turn)
    }

    /// The user allowed the one-time Bun download.
    package func installRuntime() {
        guard runtimeOffer != nil, !installingRuntime else { return }
        installingRuntime = true
        Task {
            defer { installingRuntime = false }
            do {
                try await BunRuntime.install(spawner: spawner)
                runtimeOffer = nil
                retryAfterFix()
            } catch {
                runtimeOffer = nil
                items.append(Item(kind: .error(error.localizedDescription)))
                state = .failed
            }
        }
    }

    package func declineRuntime() {
        runtimeOffer = nil
        items.append(Item(kind: .error("\(agent.name) needs Node 22 or newer, or the Bun download. Install Node, then send again.")))
        state = .failed
    }

    package func signIn(_ method: AuthMethod) {
        if method.type == "terminal" {
            TerminalLauncher.open(agent: agent, method: method, spawner: spawner)
            return
        }
        Task {
            do {
                try await acp?.authenticate(method)
                signInOptions = []
                retryAfterFix()
            } catch {
                items.append(Item(kind: .error("Sign-in failed: \(error.localizedDescription)")))
            }
        }
    }

    private static func presentTense(_ summary: String) -> String {
        for (past, present) in [("Ran ", "Running "), ("Edited ", "Editing "), ("Read ", "Reading "),
                                ("Deleted ", "Deleting "), ("Searched ", "Searching ")] where summary.hasPrefix(past) {
            return present + summary.dropFirst(past.count)
        }
        return summary
    }

    private func ask(title: String, detail: String, options: [PermissionOption] = [], respond: @escaping (ApprovalDecision) -> Void) {
        let approval = Approval(title: title, detail: detail, options: options, responders: [respond])
        approvals.append(approval)
        turnAskedApproval = true
        if let origin = turnOrigin { onTurn?(origin, .approval(id: approval.id, title: approval.title, detail: approval.detail)) }
        if !isVisible { onApprovalNeeded?(approval) }
    }

    private func handle(_ event: AgentEvent, turn: UUID) {
        guard turn == turnID else { return }
        switch event {
        case .session(let id):
            // The agent started a fresh session because it could not resume the old one. The chat keeps its thread
            // and transcript; only the agent's own context starts over.
            if threadID == nil {
                threadID = id
                agentSessionID = id
            } else if let current = agentSessionID, current != id {
                ChatLog.note("agent session \(id) replaced unresumable \(current); chat thread and \(items.count) items kept")
            } else if agentSessionID == nil {
                // The first turn of the new session after a rollover.
                if let from = rolledFrom {
                    ChatLog.note("session rollover done: thread \(threadID ?? "none"), old session \(from.id) (\(from.bytes) bytes), new session \(id)")
                }
                rolledFrom = nil
                agentSessionID = id
                pendingHandoff = nil
            }
            // Saved now, not only when the turn ends, so quitting mid-run keeps the question.
            saveThread()
        case .models(_, let list):
            models = list
            UserDefaults.standard.set(list.map { [$0.id, $0.name] }, forKey: "cachedModels.\(agent.id)")
            if let model, !list.isEmpty, !list.contains(where: { $0.id == model }) { self.model = nil }
        case .commands(let list):
            receiveCommands(list)
        case .toolUpdated, .subagentTool, .asyncTask:
            applyTranscript(event)
        case .needsSignIn(let methods):
            endTurn()
            signInOptions = methods
            items.append(Item(kind: .error("\(agent.name) needs you to sign in.")))
            state = .failed
            finishTurn(error: "\(agent.name) needs you to sign in on the Mac.")
            restoreQueue(reason: "\(agent.name) needs you to sign in on the Mac.")
            onSpokenTurnEnded?(true)
        case .needsRuntime:
            endTurn()
            // Not a failure: the chat waits for the user to allow the download.
            runtimeOffer = agent.name
            state = .idle
            finishTurn(error: "\(agent.name) needs a runtime download. Approve it on the Mac.")
            restoreQueue(reason: "\(agent.name) needs a runtime download. Approve it on the Mac.")
            onSpokenTurnEnded?(true)
        case .assistant, .toolStarted, .toolFinished:
            applyTranscript(event)
            // The summary is read as soon as its line is complete, while the rest of the reply is still being written.
            if case .assistant = event { speakSummary(final: false) }
        case .finished(let error):
            endTurn()
            if let error { items.append(Item(kind: .error(error))) }
            state = error == nil ? .done : .failed
            let hidden = error == nil && hideQuietTurn()
            saveThread()
            if let threadID { onTurnEnded?(threadID) }
            // Before the queue moves on: the next message replaces the origin this turn belongs to.
            finishTurn(error: error, noChange: hidden)
            if error == nil, !hidden { speakSummary(final: true) }
            // A reply that was read aloud needs no "finished" bubble. Failures and unspoken turns still get one.
            if !isVisible, !hidden, error != nil || !turnSummaryRead {
                let name = agentDisplayName
                onAttention?(error == nil ? "\(name) finished your task" : "\(name)'s task failed")
            }
            turnSpeaksSummary = false
            if error == nil { sendNextQueued() } else { restoreQueue(reason: "The turn before it failed, so this message did not run.") }
            if error != nil || (!isRunning && queue.isEmpty) { onSpokenTurnEnded?(error != nil) }
            rolloverIfDue()
        }
    }

    /// Reads the summary at the top of the running turn's reply, once. It is the reply's first line; a reply of one line has
    /// it only when the turn is over. Only the summary is read: the full answer stays in the chat for the speaker button.
    private func speakSummary(final: Bool) {
        guard turnSpeaksSummary, !turnSummarySpoken, let start = items.lastIndex(where: { if case .user = $0.kind { return true } else { return false } }),
              let answer = items[(start + 1)...].first(where: { if case .assistant(let text) = $0.kind { return !text.allSatisfy(\.isWhitespace) } else { return false } }),
              case .assistant(let text) = answer.kind, let summary = SpokenSummary.summary(in: text, final: final) else { return }
        turnSummarySpoken = true
        // The switch comes first: the quiet check starts polling the microphone list, which must not happen while off.
        guard speech.isEnabled(), speaksReplies(), !isQuiet() else { return }
        turnSummaryRead = true
        try? speech.speak(summary, id: answer.id)
    }

    /// Updates that arrive after the turn ended, such as a background subagent's result. They join the transcript
    /// without a turn, so the chat stays idle and new messages start at once. An update that lands while the next
    /// turn is still connecting joins that turn's reply instead of being lost.
    package func handleBackground(_ event: AgentEvent) {
        switch event {
        case .assistant, .toolStarted, .toolUpdated, .toolFinished, .subagentTool, .asyncTask: applyTranscript(event)
        default: break
        }
    }

    /// Text and tool items. Outside a running turn, text opens a new item instead of extending the last reply.
    private func applyTranscript(_ event: AgentEvent) {
        switch event {
        case .assistant(let text):
            if isRunning { activity = "Writing" }
            if case .assistant(let previous) = items.last?.kind, isRunning || items.last?.id == backgroundReply {
                items[items.count - 1].kind = .assistant(previous + text)
            } else if isRunning, let id = splitReply, let index = items.firstIndex(where: { $0.id == id }),
                      case .assistant(let previous) = items[index].kind {
                items[index].kind = .assistant(previous + text)
            } else {
                let item = Item(kind: .assistant(text))
                backgroundReply = isRunning ? nil : item.id
                items.append(item)
            }
        case .toolStarted(let id, let summary):
            if isRunning { activity = Self.presentTense(summary) }
            splitReply = nil
            let item = Item(kind: .tool(summary, ok: nil))
            toolBase[id] = summary
            toolItems[id] = item.id
            toolStarts[id] = backgroundClock()
            items.append(item)
        case .toolUpdated(let id, let summary):
            if let itemID = toolItems[id], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(_, let ok) = items[index].kind {
                toolBase[id] = summary
                items[index].kind = .tool(composedSummary(id), ok: ok)
            }
        case .subagentTool(let parent, let id, let summary, let ok):
            // A subagent's calls count on its own row. They never open an item, so the reply's text keeps one message.
            if isRunning, ok == nil { activity = Self.presentTense(summary) }
            var calls = subagentCalls[parent] ?? []
            if let index = calls.firstIndex(where: { $0.id == id }) { calls[index].ok = ok } else { calls.append((id, ok)) }
            subagentCalls[parent] = calls
            let now = backgroundClock()
            background.apply(subagentCall: id, parent: parent, summary: summary, ok: ok, title: toolBase[parent] ?? "Agent",
                             startedAt: toolStarts[parent] ?? now, steps: calls.count, now: now)
            if let itemID = toolItems[parent], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(_, let parentOK) = items[index].kind {
                items[index].kind = .tool(composedSummary(parent), ok: parentOK)
            }
            if !isRunning { saveThread() }
        case .asyncTask(let update):
            applyAsyncTask(update)
        case .toolFinished(let id, let ok):
            background.finishAgent(id, ok: ok, result: nil, now: backgroundClock())
            if isRunning { activity = "Thinking" }
            if let itemID = toolItems[id], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(let summary, _) = items[index].kind {
                items[index].kind = .tool(summary, ok: ok)
            }
            if !isRunning { saveThread() }
        default:
            break
        }
    }

    private func applyAsyncTask(_ update: AsyncTaskUpdate) {
        background.apply(update, now: backgroundClock())
        guard let item = background.item(update.id), item.kind != .workflow, let path = item.outputFile else { return }
        let id = update.id
        Task { [weak self] in
            guard let lines = await self?.outputTail(path) else { return }
            self?.background.setOutput(id, lines: lines)
        }
    }

    // MARK: Background work list

    /// The user opened the list. Failures that were waiting for them count as seen.
    package func openBackground() { background.markSeen() }

    /// Removes finished rows. Running and waiting ones stay.
    package func clearFinishedBackground() { background.clearFinished() }

    /// Stops one row. A shell or workflow gets the agent's stop call and its row changes when the agent reports `stopped`. A job
    /// goes through the job service. An agent or a monitor cannot be stopped.
    package func stopBackground(_ id: String) {
        guard let item = background.item(id), item.stoppable else { return }
        switch item.kind {
        case .job: jobStopper?(String(id.dropFirst("job:".count)))
        case .shell, .workflow: if let asyncTaskStopper { asyncTaskStopper(id) } else { acp?.stopAsyncTask(id) }
        case .agent, .monitor: break
        }
    }

    /// Mirrors the Mac's job store into the list.
    package func syncJobs(_ jobs: [Job]) { background.sync(jobs: jobs, now: backgroundClock()) }

    /// A tool row's summary with its subagent's tool-call count, e.g. "Run research · 3 tool calls".
    private func composedSummary(_ id: String) -> String {
        let base = toolBase[id] ?? ""
        let count = subagentCalls[id]?.count ?? 0
        guard count > 0 else { return base }
        return "\(base) · \(count) tool call\(count == 1 ? "" : "s")"
    }

    // MARK: Session rollover

    /// Moves the thread to a fresh agent session when the agent's transcript file is over the limit and the chat is idle:
    /// no turn running, no approval or form open, no message queued. Called after each finished turn, at launch, and when
    /// an approval or form that held it back is answered. A busy chat is left alone and rechecked at its next idle moment.
    package func rolloverIfDue() {
        rolloverWaiting = false
        guard rollover == nil, let threadID, let workspace, let session = agentSessionID, !items.isEmpty,
              let bytes = sessionSize(agent.id, workspace.path, session), bytes > rolloverLimit() else { return }
        // Threads that belong to a job, an automation or voice mode have their own limits.
        if let saved = ThreadStore.load(threadID), saved.automation != nil || saved.job != nil || saved.voice == true { return }
        guard !isRunning, approvals.isEmpty, forms.isEmpty, queue.isEmpty else {
            rolloverWaiting = true
            return
        }
        let id = UUID()
        rollover = id
        let before = state
        state = .running
        activity = "Starting a fresh session"
        runStartedAt = Date()
        let turn = ACPTurn(prompt: SessionHandoff.prompt, preamble: nil, workspace: workspace, resume: session, model: model, images: [], files: [])
        Task { [weak self] in
            guard let self else { return }
            let summary = await self.requestHandoff(turn)
            self.finishRollover(id, thread: threadID, old: session, bytes: bytes, summary: summary, stateBefore: before)
        }
    }

    /// Runs the summary request on the old session. Its events never reach the transcript. Nil when the turn failed or timed out.
    private func requestHandoff(_ turn: ACPTurn) async -> String? {
        let collector = HandoffCollector()
        let timeout = handoffTimeout
        let backend: ACPBackend? = turnRunner == nil ? (acp?.agent == agent ? acp : makeBackend()) : nil
        return await withCheckedContinuation { continuation in
            collector.wait(timeout: timeout, continuation)
            Task { @MainActor in
                if let turnRunner = self.turnRunner {
                    await turnRunner(turn) { collector.receive($0) }
                } else {
                    await backend?.runTurn(turn) { collector.receive($0) }
                }
            }
        }
    }

    private func finishRollover(_ id: UUID, thread: String, old: String, bytes: Int64, summary: String?, stateBefore: State) {
        // The user stopped the chat, or left the thread, while the summary was being written.
        guard rollover == id, threadID == thread else { return }
        rollover = nil
        state = stateBefore == .running ? .idle : stateBefore
        activity = nil
        runStartedAt = nil
        let fromAgent = SessionHandoff.clean(summary)
        pendingHandoff = SessionHandoff.compose(summary: fromAgent ?? SessionHandoff.fallbackSummary(items: items), items: items)
        previousSessions.append(old)
        agentSessionID = nil
        rolledFrom = (old, bytes)
        items.append(Item(kind: .notice(SessionHandoff.systemLine)))
        shutdownAgent()
        ChatLog.note("session rollover: thread \(thread) left session \(old) (\(bytes) bytes), summary from \(fromAgent == nil ? "chat messages" : "the agent"); the next message starts the new session")
        saveThread()
        pruneOldSessions()
        sendNextQueued()
    }

    /// Deletes transcripts of earlier sessions that are past `chat.sessionRetentionDays`. It only touches ids that threads
    /// recorded as left behind, never a session any thread still runs on.
    package func pruneOldSessions() {
        AgentTranscript.pruneInBackground(alsoActive: agentSessionID.map { Set([$0]) } ?? [])
    }

    private func endTurn() {
        turnID = nil
        activity = nil
        lastRunDuration = runStartedAt.map { Date().timeIntervalSince($0) }
        runStartedAt = nil
        for approval in approvals {
            approval.respond(.deny("The run ended"))
            onApprovalResolved?(approval.id)
            if let origin = turnOrigin { onTurn?(origin, .approvalDecided(id: approval.id, outcome: .ended)) }
        }
        approvals = []
        cancelForms()
    }
}
