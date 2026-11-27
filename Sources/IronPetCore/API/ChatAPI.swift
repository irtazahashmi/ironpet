import Foundation

/// Who sent a chat message when it was not typed on the Mac. The chat tells the sender how its turn goes (`ChatAPI.onTurn`),
/// so a client only hears about its own messages.
package struct ChatOrigin: Codable, Equatable, Hashable {
    package init(client: String, ref: String, device: String? = nil) {
        self.client = client
        self.ref = ref
        self.device = device
    }

    /// The kind of client: `telegram`, `ios`.
    package var client: String
    /// The client's own id for the conversation, such as a Telegram chat id or a device id.
    package var ref: String
    /// The paired device the message came from, the id of its `ClientSession.deviceID`. Nil for clients that are not a device, such as
    /// Telegram, and for the Mac's own input box. "My screen" in this turn means this device's screen.
    package var device: String?

    package static let telegramClient = "telegram"
    /// Messages an automation sent into the chat.
    package static let automationClient = "automation"
    /// A prompt or follow-up that a background job ran.
    package static let jobClient = "job"
    /// Something the user said in voice mode on the Mac.
    package static let voiceClient = "voice"
    /// Something the user sent from the iPhone app.
    package static let iosClient = "ios"
    /// A prompt a button on a dashboard sent. `ref` is the dashboard's id.
    package static let dashboardClient = "dashboard"

    /// The badge under a message that came from the iPhone. Nil for any other client.
    package static func badge(for client: String?) -> (label: String, help: String)? {
        client == iosClient ? ("iPhone", "Sent from iPhone") : nil
    }

    package static func telegram(chat: Int64) -> ChatOrigin { ChatOrigin(client: telegramClient, ref: String(chat)) }

    /// A message from a paired iPhone. Its `ref` and `device` are both the device id.
    package static func ios(device: String) -> ChatOrigin { ChatOrigin(client: iosClient, ref: device, device: device) }
}

package typealias ChatItem = ChatSession.Item
package typealias ChatReply = ChatSession.Reply
package typealias ChatTurnEvent = ChatSession.TurnEvent
package typealias ChatApprovalOutcome = ChatSession.ApprovalOutcome

/// A file a remote client sends with a message. The chat saves it on this Mac and hands the agent its path.
package struct ChatUpload: Codable, Equatable {
    package init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }

    package var fileName: String
    package var data: Data
}

/// A message for the open chat.
package struct SendChatRequest: Codable, Equatable {
    package init(text: String, origin: ChatOrigin? = nil, files: [URL] = [], uploads: [ChatUpload] = [], reply: ChatReply? = nil,
                 selection: FrontSelection? = nil, agentId: String? = nil, spoken: Bool? = nil) {
        self.agentId = agentId
        self.spoken = spoken
        self.text = text
        self.origin = origin
        self.files = files
        self.uploads = uploads
        self.reply = reply
        self.selection = selection
    }

    package var text: String
    /// Who is sending. Nil is the Mac's own input box: a missing folder asks for one, a running turn queues the message, and the
    /// reply is read aloud when that is on. Any other sender never changes the chat's thread or folder.
    package var origin: ChatOrigin?
    /// Files already on this Mac, such as a screenshot or a file the Mac user dropped.
    package var files: [URL] = []
    /// Files the sender carries, saved on this Mac first.
    package var uploads: [ChatUpload] = []
    package var reply: ChatReply?
    /// Text selected in another app when the Mac chat opened. Ignored for remote origins.
    package var selection: FrontSelection?
    /// The agent whose chat gets the message. Nil is agent 1.
    package var agentId: String?
    /// The user said the message aloud (the voice shortcut). Its reply starts with a summary that is read aloud. Only the Mac's own input.
    package var spoken: Bool?
}

package enum ChatSendOutcome: String, Codable {
    /// The message was empty.
    case ignored
    /// A turn started.
    case sent
    /// The agent was busy, so the message waits its turn.
    case queued
    /// A background job runs in this thread and took the message.
    case toJob
    /// No folder is chosen yet, so nothing was sent. Choose one with `useFolder` or `useNoProject`.
    case needsFolder
}

package struct ChatSendResult: Codable, Equatable {
    package init(outcome: ChatSendOutcome) {
        self.outcome = outcome
    }

    package var outcome: ChatSendOutcome
}

/// Mac messages that were cancelled before they started, handed back so the sender can edit them.
package struct ChatRestoredDraft: Codable, Equatable {
    package init(text: String, files: [URL], reply: ChatReply? = nil, selection: FrontSelection? = nil) {
        self.text = text
        self.files = files
        self.reply = reply
        self.selection = selection
    }

    package var text: String
    package var files: [URL]
    package var reply: ChatReply?
    package var selection: FrontSelection?
}

package struct ChatStopResult: Codable, Equatable {
    package init(restored: ChatRestoredDraft? = nil) {
        self.restored = restored
    }

    package var restored: ChatRestoredDraft?
}

/// An approval card as a client that cannot draw the Mac's sees it.
package struct ChatApprovalInfo: Codable, Equatable, Identifiable {
    package init(id: UUID, title: String, detail: String, options: [PermissionOption]? = nil, agentId: String? = nil, agentName: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.options = options
        self.agentId = agentId
        self.agentName = agentName
    }

    package var id: UUID
    package var title: String
    package var detail: String
    /// The answers the agent offered, in its order. Nil from a build that predates them.
    package var options: [PermissionOption]?
    /// The agent that is asking, and its name, so a client with several agents can say who wants what. Nil from a build that predates
    /// them, and for a background request, which belongs to a job or an automation and not to one agent's chat.
    package var agentId: String?
    package var agentName: String?
}

package struct DecideApprovalRequest: Codable, Equatable {
    package init(id: UUID, allow: Bool, option: String? = nil, agentId: String? = nil) {
        self.agentId = agentId
        self.id = id
        self.allow = allow
        self.option = option
    }

    package var id: UUID
    package var allow: Bool
    /// The `optionId` the user chose. When set it wins over `allow`.
    package var option: String?
    /// The agent whose chat holds the approval. Nil is agent 1.
    package var agentId: String?
}

/// A question the agent asked, with what has been entered so far.
package struct ChatFormInfo: Codable, Equatable, Identifiable {
    package init(id: UUID, form: ElicitationForm, answers: [String: ElicitationValue], agentId: String? = nil, agentName: String? = nil) {
        self.id = id
        self.form = form
        self.answers = answers
        self.agentId = agentId
        self.agentName = agentName
    }

    package var id: UUID
    package var form: ElicitationForm
    package var answers: [String: ElicitationValue]
    /// The agent that is asking, and its name. Nil from a build that predates them.
    package var agentId: String?
    package var agentName: String?
}

package struct AnswerFormRequest: Codable, Equatable {
    package init(id: UUID, field: String, value: ElicitationValue? = nil, agentId: String? = nil) {
        self.agentId = agentId
        self.id = id
        self.field = field
        self.value = value
    }

    package var id: UUID
    package var field: String
    /// Nil clears the answer.
    package var value: ElicitationValue?
    /// The agent whose chat holds the form. Nil is agent 1.
    package var agentId: String?
}

/// `chat.openThread`: a thread, and the agent whose chat opens it.
package struct ChatOpenRequest: Codable, Equatable {
    package init(id: String, agentId: String? = nil) {
        self.id = id
        self.agentId = agentId
    }

    package var id: String
    package var agentId: String?
}

/// `chat.submitForm` and `chat.skipForm`: a form, and the agent whose chat holds it.
package struct ChatFormTarget: Codable, Equatable {
    package init(id: UUID, agentId: String? = nil) {
        self.id = id
        self.agentId = agentId
    }

    package var id: UUID
    package var agentId: String?
}

package struct ChatQueuedInfo: Codable, Equatable, Identifiable {
    package init(id: UUID, text: String, files: [URL], reply: ChatReply? = nil, fromMac: Bool, waitsForAnswer: Bool? = nil) {
        self.id = id
        self.text = text
        self.files = files
        self.reply = reply
        self.fromMac = fromMac
        self.waitsForAnswer = waitsForAnswer
    }

    package var id: UUID
    package var text: String
    package var files: [URL]
    package var reply: ChatReply?
    /// Typed on this Mac, so a stop gives it back to the draft. Others are told their turn failed.
    package var fromMac: Bool
    /// True while an open approval or form holds the message. The agent takes it into the running turn once that is answered.
    package var waitsForAnswer: Bool? = nil
}

package struct ChatThreadInfo: Codable, Equatable, Identifiable {
    package init(
        id: String,
        title: String,
        workspace: String,
        updatedAt: Date,
        agent: String,
        automation: String? = nil,
        automationName: String? = nil,
        voice: Bool? = nil,
        ref: String? = nil,
        agentId: String? = nil
    ) {
        self.ref = ref
        self.agentId = agentId
        self.id = id
        self.title = title
        self.workspace = workspace
        self.updatedAt = updatedAt
        self.agent = agent
        self.automation = automation
        self.automationName = automationName
        self.voice = voice
    }

    package var id: String
    package var title: String
    package var workspace: String
    package var updatedAt: Date
    package var agent: String
    /// The automation whose run this thread holds, if any.
    package var automation: String?
    package var automationName: String?
    /// A voice-mode conversation on the Mac.
    package var voice: Bool?
    /// The thread's public id (`chat_…`).
    package var ref: String?
    /// The agent that owns the thread. Nil for a thread saved before agents owned threads, which is agent 1's.
    package var agentId: String?

    package var isAutomationRun: Bool { automation != nil }
}

package struct ChatStatus: Codable, Equatable {
    package init(
        state: String,
        running: Bool,
        title: String,
        threadID: String? = nil,
        queued: Int,
        pendingApprovals: Int,
        pendingForms: Int,
        activity: String? = nil,
        runStartedAt: Date? = nil,
        lastRunDuration: TimeInterval? = nil
    ) {
        self.state = state
        self.running = running
        self.title = title
        self.threadID = threadID
        self.queued = queued
        self.pendingApprovals = pendingApprovals
        self.pendingForms = pendingForms
        self.activity = activity
        self.runStartedAt = runStartedAt
        self.lastRunDuration = lastRunDuration
    }

    /// `idle`, `running`, `done` or `failed`.
    package var state: String
    package var running: Bool
    /// The first message of the open chat, or "New chat".
    package var title: String
    package var threadID: String?
    package var queued: Int
    package var pendingApprovals: Int
    package var pendingForms: Int
    /// What the agent is doing now, such as "Running `npm test`".
    package var activity: String?
    package var runStartedAt: Date?
    package var lastRunDuration: TimeInterval?
}

package struct ChatNamedInfo: Codable, Equatable, Identifiable {
    package init(id: String, name: String, detail: String = "") {
        self.id = id
        self.name = name
        self.detail = detail
    }

    package var id: String
    package var name: String
    package var detail = ""
}

package enum ChatCommandKind: String, Codable {
    /// A command the agent offers after a slash.
    case command
    /// A skill the agent offers after a slash. Agents that report skills as commands show as `command`.
    case skill
}

/// One row of the slash popup: what the agent offers after a `/`. A client fetches the list when the user types `/`, then
/// filters and highlights it itself.
package struct ChatCommandInfo: Codable, Equatable, Identifiable {
    package init(name: String, detail: String, hint: String? = nil, kind: ChatCommandKind = .command) {
        self.name = name
        self.detail = detail
        self.hint = hint
        self.kind = kind
    }

    package var id: String { name }
    package var name: String
    package var detail: String
    /// What to type after the name, such as `<path>`.
    package var hint: String?
    package var kind: ChatCommandKind = .command
}

/// Which agent's commands to list. With `thread`, the agent that thread belongs to; else `agent`; else the open chat's agent.
package struct ChatCommandsRequest: Codable, Equatable {
    package init(thread: String? = nil, agent: String? = nil) {
        self.thread = thread
        self.agent = agent
    }

    package var thread: String?
    package var agent: String?
}

/// Which agent, model and folder the chat runs with, and what is blocking it.
package struct ChatOptions: Codable, Equatable {
    package init(
        agent: ChatNamedInfo,
        agents: [ChatNamedInfo],
        model: String? = nil,
        models: [ChatNamedInfo],
        folder: String? = nil,
        folderLabel: String,
        recentFolders: [String],
        needsFolder: Bool,
        modes: [ChatNamedInfo] = [],
        mode: String? = nil,
        runtimeOffer: String? = nil,
        installingRuntime: Bool,
        signInMethods: [ChatNamedInfo]
    ) {
        self.agent = agent
        self.agents = agents
        self.model = model
        self.models = models
        self.folder = folder
        self.folderLabel = folderLabel
        self.recentFolders = recentFolders
        self.needsFolder = needsFolder
        self.modes = modes
        self.mode = mode
        self.runtimeOffer = runtimeOffer
        self.installingRuntime = installingRuntime
        self.signInMethods = signInMethods
    }

    package var agent: ChatNamedInfo
    package var agents: [ChatNamedInfo]
    package var model: String?
    package var models: [ChatNamedInfo]
    package var folder: String?
    package var folderLabel: String
    package var recentFolders: [String]
    package var needsFolder: Bool
    /// The permission modes the agent advertises, empty until its session starts, and the current one.
    package var modes: [ChatNamedInfo]
    package var mode: String?
    /// The agent the chat offers to download a runtime for, or nil.
    package var runtimeOffer: String?
    package var installingRuntime: Bool
    /// Ways to sign in when the agent asked for it.
    package var signInMethods: [ChatNamedInfo]
}

/// Everything a client reads about the chat, at one moment.
package struct ChatSnapshot: Codable, Equatable {
    package init(
        status: ChatStatus,
        messages: [ChatItem],
        approvals: [ChatApprovalInfo],
        forms: [ChatFormInfo],
        queue: [ChatQueuedInfo],
        threads: [ChatThreadInfo],
        options: ChatOptions
    ) {
        self.status = status
        self.messages = messages
        self.approvals = approvals
        self.forms = forms
        self.queue = queue
        self.threads = threads
        self.options = options
    }

    package var status: ChatStatus
    package var messages: [ChatItem]
    package var approvals: [ChatApprovalInfo]
    package var forms: [ChatFormInfo]
    package var queue: [ChatQueuedInfo]
    package var threads: [ChatThreadInfo]
    package var options: ChatOptions
}

/// The one shared chat. The Mac's chat view model and the Telegram bridge are two clients of it, and the iOS app will be a third:
/// they send, stop, answer approvals and forms, and open threads through the same calls. Everything here is a `Codable` value or
/// an event on the bus: `chat.item` carries the id of the message that was added or changed (no id means read them all again) and
/// `chat.state` says what else moved (`approvals`, `forms`, `queue`, `draft`, or no id for the turn state). Draft text, the slash
/// popup, find and voice are the Mac window's own state and live in `ChatViewModel`, not here.
@MainActor
package final class ChatAPI {
    private let session: ChatSession
    private let files: FileIntake
    /// The chat this API serves, for the host that owns it. Clients never read it.
    package var chatSession: ChatSession { session }
    package var fileIntake: FileIntake { files }
    /// The agent whose chat this is. Agent 1 unless `AgentChats` made the API for another agent.
    package var agentID: String { session.ownerAgentID }
    private var listeners: [UUID: (ChatOrigin, ChatTurnEvent) -> Void] = [:]
    private var formListeners: [UUID: () -> Void] = [:]
    private var backgroundListeners: [UUID: (BackgroundPermissions.Request?, UUID?, BackgroundPermissions.Outcome?) -> Void] = [:]
    private var stopBackground: (() -> Void)?

    /// Permission requests from jobs and automation sessions. They show up in `approvals()` next to the chat's own, with the same
    /// options, and `decide` answers them. `status().pendingApprovals` leaves them out: they do not hold the chat.
    package var background: BackgroundPermissions? {
        didSet {
            stopBackground?()
            stopBackground = background?.observe(raised: { [weak self] request in
                guard let self else { return }
                session.events?.publish(.chatState, id: "approvals", agentId: session.ownerAgentID == AgentOwner.defaultID ? nil : session.ownerAgentID)
                for listener in Array(backgroundListeners.values) { listener(request, nil, nil) }
            }, resolved: { [weak self] id, outcome in
                guard let self else { return }
                session.events?.publish(.chatState, id: "approvals", agentId: session.ownerAgentID == AgentOwner.defaultID ? nil : session.ownerAgentID)
                for listener in Array(backgroundListeners.values) { listener(nil, id, outcome) }
            })
        }
    }

    /// Hears a background request as it is raised (first value) and as it is resolved (the id and how).
    @discardableResult
    package func onBackgroundApproval(_ listener: @escaping (BackgroundPermissions.Request?, UUID?, BackgroundPermissions.Outcome?) -> Void) -> () -> Void {
        let id = UUID()
        backgroundListeners[id] = listener
        return { [weak self] in self?.backgroundListeners[id] = nil }
    }

    /// `files` receives what a client uploads. `IronPetAPI` passes the platform's; the default copies them into the attachments folder and converts nothing.
    package init(session: ChatSession, files: FileIntake = FolderFileIntake(directory: Paths.attachments)) {
        self.session = session
        self.files = files
        session.onTurn = { [weak self] origin, event in
            guard let self else { return }
            for listener in Array(listeners.values) { listener(origin, event) }
        }
        session.onFormsChanged = { [weak self] in
            guard let self else { return }
            for listener in Array(formListeners.values) { listener() }
        }
    }

    /// The models an agent offered in its last session, kept between runs.
    package static func cachedModels(forAgent id: String) -> [ChatNamedInfo] {
        guard let agent = AgentCatalog.agent(id: id) else { return [] }
        return ChatSession.cachedModels(for: agent).map { ChatNamedInfo(id: $0.id, name: $0.name) }
    }

    // MARK: Turns from other clients

    /// Hears how the turns of messages sent with an origin go: queued, started, an approval to answer, the answer, a failure.
    @discardableResult
    package func onTurn(_ listener: @escaping (ChatOrigin, ChatTurnEvent) -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// Hears that a form opened, closed or got an answer, whoever started the turn. Read `forms()` for what is open now.
    @discardableResult
    package func onFormsChanged(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        formListeners[id] = listener
        return { [weak self] in self?.formListeners[id] = nil }
    }

    /// Forgets an origin's queued messages and the answer it was waiting for.
    package func cancel(from origin: ChatOrigin) async { session.cancel(from: origin) }

    // MARK: Reading

    /// All the reads at once. It does not wait for anything, so a window can draw its first frame, or a test can check the chat, at once.
    package func snapshot() -> ChatSnapshot {
        ChatSnapshot(status: currentStatus, messages: session.items, approvals: currentApprovals, forms: currentForms, queue: currentQueue,
                     threads: currentThreads, options: currentOptions)
    }

    package func status() async -> ChatStatus { currentStatus }

    private var currentStatus: ChatStatus {
        ChatStatus(state: Self.name(session.state), running: session.isRunning, title: title, threadID: session.threadID,
                   queued: session.userQueueCount, pendingApprovals: session.approvals.count, pendingForms: session.forms.count,
                   activity: session.activity, runStartedAt: session.runStartedAt, lastRunDuration: session.lastRunDuration)
    }

    /// The open chat's messages, oldest first.
    package func messages() async -> [ChatItem] { session.items }

    /// The message with this id as it is now, without a suspension point. The event socket reads it when it sends a `chat.item`.
    package func currentItem(_ id: UUID) -> ChatItem? { session.items.first { $0.id == id } }

    /// One message, for a client that heard a `chat.item` event with its id.
    package func message(_ id: UUID) async throws -> ChatItem {
        guard let item = session.items.first(where: { $0.id == id }) else { throw APIError.notFound("no message with id \"\(id.uuidString)\"") }
        return item
    }

    package func approvals() async -> [ChatApprovalInfo] { currentApprovals }
    package func forms() async -> [ChatFormInfo] { currentForms }
    package func queue() async -> [ChatQueuedInfo] { currentQueue }
    package func threads() async -> [ChatThreadInfo] { currentThreads }

    /// The threads this agent owns, newest first. Nil is agent 1, which is what the Mac's window shows. An id no agent has is `notFound`.
    package func threads(agentId: String?) async throws -> [ChatThreadInfo] {
        let agent = try AgentOwner.resolve(agentId, registry: registry)
        if agent == session.ownerAgentID { return currentThreads }
        let history = ThreadStore.recent(agent: agent)
        let refs = records?.refs(.chat, history.map(\.id)) ?? [:]
        return history.map { Self.info($0, ref: refs[$0.id]) }
    }
    package func options() async -> ChatOptions { currentOptions }

    /// The slash commands for an agent, in the agent's order. The list is data: nothing here depends on what the user has typed. The
    /// open chat's agent returns what its session reported last; any other agent returns what was kept from its last session.
    package func commands(_ request: ChatCommandsRequest = ChatCommandsRequest()) async throws -> [ChatCommandInfo] {
        var agentID = request.agent ?? session.agent.id
        if let thread = request.thread {
            guard let saved = ThreadStore.load(thread) else { throw APIError.notFound("no thread with id \"\(thread)\"") }
            agentID = saved.agent
        }
        guard AgentCatalog.agent(id: agentID) != nil else { throw APIError.notFound("no agent \"\(agentID)\"") }
        let list = agentID == session.agent.id ? session.commands : SlashCommand.cached(for: agentID)
        return list.map { ChatCommandInfo(name: $0.name, detail: $0.detail, hint: $0.hint, kind: .command) }
    }

    private var currentApprovals: [ChatApprovalInfo] {
        session.approvals.map { ChatApprovalInfo(id: $0.id, title: $0.title, detail: $0.detail, options: $0.options, agentId: agentID, agentName: agentName) }
            + (background?.pending ?? []).map { ChatApprovalInfo(id: $0.id, title: $0.heading, detail: $0.detail, options: $0.options) }
    }
    private var currentForms: [ChatFormInfo] {
        session.forms.map { ChatFormInfo(id: $0.id, form: $0.form, answers: $0.answers, agentId: agentID, agentName: agentName) }
    }

    /// The name of the agent whose chat this is, from its record.
    package var agentName: String? { registry?.get(session.ownerAgentID)?.name }

    private var currentQueue: [ChatQueuedInfo] {
        session.queue.filter { $0.automation == nil && !$0.notice }.map {
            ChatQueuedInfo(id: $0.id, text: $0.text, files: $0.attachments, reply: $0.reply, fromMac: $0.origin == nil,
                            waitsForAnswer: $0.steerable && session.queueWaitsForAnswer ? true : nil)
        }
    }

    private var currentThreads: [ChatThreadInfo] {
        let history = session.history
        let refs = records?.refs(.chat, history.map(\.id)) ?? [:]
        return history.map { Self.info($0, ref: refs[$0.id]) }
    }

    private static func info(_ thread: ChatThread, ref: String? = nil) -> ChatThreadInfo {
        ChatThreadInfo(id: thread.id, title: thread.title, workspace: thread.workspace, updatedAt: thread.updatedAt, agent: thread.agent,
                       automation: thread.automation, automationName: thread.automationName, voice: thread.voice, ref: ref,
                       agentId: thread.agentId)
    }

    /// The public id of a message in a thread (`msg_…`), created on first use. Nil when the chat database is not attached.
    package func messageRef(thread: String, item: UUID) -> String? {
        records?.ref(.msg, "\(thread)/\(item.uuidString)")
    }

    /// The public ids of the chat threads and messages, set by the API owner once the database is open.
    package var records: RecordRefs?

    /// The agents on this install, for checking an agent id a call names. Set by the API owner when there is a database.
    package var registry: AgentRegistry?

    private var currentOptions: ChatOptions {
        ChatOptions(agent: Self.info(session.agent), agents: session.agents.map(Self.info), model: session.model,
                    models: session.models.map { ChatNamedInfo(id: $0.id, name: $0.name) }, folder: session.workspace?.path,
                    folderLabel: session.workspaceLabel, recentFolders: session.recents.map(\.path), needsFolder: session.needsWorkspace,
                    modes: session.agentModes.map { ChatNamedInfo(id: $0.id, name: $0.name, detail: $0.detail ?? "") }, mode: session.agentMode, runtimeOffer: session.runtimeOffer, installingRuntime: session.installingRuntime,
                    signInMethods: session.signInOptions.map { ChatNamedInfo(id: $0.id, name: $0.name, detail: $0.detail) })
    }

    // MARK: Sending and stopping

    package func send(_ request: SendChatRequest) async throws -> ChatSendResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = request.files + (try save(request.uploads))
        guard !text.isEmpty || !files.isEmpty else {
            if request.origin == nil { return ChatSendResult(outcome: .ignored) }
            throw APIError.invalid("the message is empty")
        }
        guard let origin = request.origin else {
            return ChatSendResult(outcome: Self.outcome(session.submitLocal(text, files: files, reply: request.reply,
                                                                            selection: request.selection, spoken: request.spoken == true)))
        }
        let before = session.queue.count
        session.submit(text, from: origin, files: files, reply: request.reply)
        return ChatSendResult(outcome: session.queue.count > before ? .queued : .sent)
    }

    /// Stops the running turn and answers what it cancelled. Queued messages that were typed on the Mac come back as a draft.
    /// With `keepDraft`, the draft stays for the Mac's own input to take, so a client that is not the Mac cannot swallow it.
    package func stop(keepDraft: Bool = false) async -> ChatStopResult {
        session.stop()
        return ChatStopResult(restored: keepDraft ? nil : await takeRestoredDraft())
    }

    /// Mac messages that a stop or a failed start cancelled, once. A client hears `chat.state` with the id `draft` when there are some.
    package func takeRestoredDraft() async -> ChatRestoredDraft? {
        session.takeRestoredDraft().map {
            ChatRestoredDraft(text: $0.text, files: $0.attachments, reply: $0.reply, selection: $0.selection)
        }
    }

    package func removeQueued(_ id: UUID) async { session.removeQueued(id) }

    // MARK: Approvals and questions

    /// Allows or denies a tool call, the same as the Allow and Deny buttons on the Mac.
    package func decide(_ request: DecideApprovalRequest) async throws {
        if let background, background.has(request.id) {
            if let option = request.option {
                guard background.answer(request.id, optionID: option) else { throw APIError.invalid("the agent did not offer that option") }
            } else {
                background.answer(request.id, allow: request.allow)
            }
            return
        }
        guard session.hasPendingApproval(request.id) else { throw APIError.notFound("that approval is no longer waiting") }
        if let option = request.option {
            guard session.approvals.first(where: { $0.id == request.id })?.options.contains(where: { $0.id == option }) == true else {
                throw APIError.invalid("the agent did not offer that option")
            }
            session.decide(id: request.id, optionID: option)
        } else {
            session.decide(id: request.id, allow: request.allow)
        }
    }

    package func answerForm(_ request: AnswerFormRequest) async throws {
        guard session.forms.contains(where: { $0.id == request.id }) else { throw APIError.notFound("that question is no longer waiting") }
        session.setAnswer(form: request.id, field: request.field, request.value)
    }

    package func submitForm(_ id: UUID) async throws {
        guard let form = session.forms.first(where: { $0.id == id }) else { throw APIError.notFound("that question is no longer waiting") }
        guard form.form.canSubmit(form.answers) else { throw APIError.invalid("a required answer is missing") }
        session.submitForm(id)
    }

    package func skipForm(_ id: UUID) async throws {
        guard session.forms.contains(where: { $0.id == id }) else { throw APIError.notFound("that question is no longer waiting") }
        session.skipForm(id)
    }

    // MARK: Threads

    /// Opens a saved thread in the chat, stopping the running turn.
    package func openThread(_ id: String) async throws {
        guard let thread = ThreadStore.load(id), thread.ownerAgentID == session.ownerAgentID else {
            throw APIError.notFound("no thread with id \"\(id)\"")
        }
        session.open(thread)
    }

    package func newChat() async { session.newChat() }

    /// A saved thread to read, without opening it.
    package func thread(_ id: String) async throws -> (info: ChatThreadInfo, items: [ChatItem]) {
        guard let thread = ThreadStore.load(id) else { throw APIError.notFound("no thread with id \"\(id)\"") }
        return (Self.info(thread, ref: records?.ref(.chat, id)), thread.items)
    }

    // MARK: Agent, model and folder

    package func setAgent(_ id: String) async throws {
        guard let agent = session.agents.first(where: { $0.id == id }) ?? AgentCatalog.agent(id: id) else { throw APIError.notFound("no agent \"\(id)\"") }
        guard !session.isRunning else { throw APIError.conflict("the agent is working") }
        session.setAgent(agent)
    }

    /// Nil uses the agent's default model.
    package func setModel(_ id: String?) async { session.model = id }

    package func setMode(_ id: String) async { session.setMode(id) }

    /// Chooses the folder the chat works in. A different folder starts a new chat.
    package func useFolder(_ path: String) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw APIError.invalid("\"\(path)\" is not a folder on this Mac")
        }
        session.use(URL(fileURLWithPath: path))
    }

    /// For general questions that are not about a project.
    package func useNoProject() async { session.useNoProject() }

    package func installRuntime() async { session.installRuntime() }
    package func declineRuntime() async { session.declineRuntime() }

    package func signIn(_ methodID: String) async throws {
        guard let method = session.signInOptions.first(where: { $0.id == methodID }) else { throw APIError.notFound("no sign-in method \"\(methodID)\"") }
        session.signIn(method)
    }

    package func retryAfterFix() async { session.retryAfterFix() }

    // MARK: Notices

    /// Adds an error line to the transcript, such as a voice note that could not be transcribed. Returns its id.
    package func addNotice(_ message: String) async -> UUID { session.appendNotice(message) }

    package func removeMessage(_ id: UUID) async { session.removeItem(id) }

    // MARK: Helpers

    private var title: String {
        guard let first = session.items.lazy.compactMap({ item -> String? in
            if case .user(let text) = item.kind { return text } else { return nil }
        }).first else { return "New chat" }
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }

    private func save(_ uploads: [ChatUpload]) throws -> [URL] {
        guard !uploads.isEmpty else { return [] }
        return try uploads.map { upload in
            // A file name only: a remote client must not choose where on this Mac the file lands.
            try files.save(upload.data, named: (upload.fileName as NSString).lastPathComponent)
        }
    }

    private static func info(_ agent: ACPAgent) -> ChatNamedInfo { ChatNamedInfo(id: agent.id, name: agent.name) }

    private static func name(_ state: ChatSession.State) -> String {
        switch state {
        case .idle: return "idle"
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private static func outcome(_ send: ChatSession.LocalSend) -> ChatSendOutcome {
        switch send {
        case .ignored: return .ignored
        case .sent: return .sent
        case .queued: return .queued
        case .toJob: return .toJob
        case .needsFolder: return .needsFolder
        }
    }
}
