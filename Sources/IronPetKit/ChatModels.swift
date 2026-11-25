import Foundation

// The phase 3 chat: the one shared chat the Mac has open, as `RemoteChat` writes it. Keys are snake_case. Every field a newer Mac may
// add or drop is optional, and `kind` is a plain string, so an item kind this app does not know decodes like any other.

/// A quote of an earlier message, kept with the message that answers it.
public struct RemoteChatReply: Codable, Equatable, Hashable, Sendable {
    public var itemID: String
    public var sender: String
    public var text: String
    public var selection: Bool?
    public var fromUser: Bool?

    enum CodingKeys: String, CodingKey {
        case sender, text, selection
        case itemID = "item_id"
        case fromUser = "from_user"
    }

    public init(itemID: String, sender: String, text: String, selection: Bool? = nil, fromUser: Bool? = nil) {
        self.itemID = itemID; self.sender = sender; self.text = text; self.selection = selection; self.fromUser = fromUser
    }
}

public struct RemoteFormLine: Codable, Equatable, Hashable, Sendable {
    public var question: String
    public var answer: String
    public init(question: String, answer: String) { self.question = question; self.answer = answer }
}

/// How a row of the transcript draws. An unknown `kind` is `.unsupported` and carries whatever text the item has.
public enum RemoteChatRow: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case tool(String, ok: Bool?)
    case error(String)
    /// A file sent with a message. `isImage` tells a photo from another file.
    case attachment(fileName: String, isImage: Bool)
    case form(message: String, skipped: Bool, lines: [RemoteFormLine])
    /// A system notice from IronPet. The first line is its label and the rest shows when it is expanded.
    case notice(String)
    case unsupported(String)
}

public struct RemoteChatItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    /// `user`, `assistant`, `tool`, `error`, `screenshot` or `form` today. The Mac may add more.
    public var kind: String
    public var date: Date?
    /// The client a user message came from: `ios`, `telegram`, `voice`... Nil for the Mac.
    public var origin: String?
    public var reply: RemoteChatReply?
    public var text: String?
    public var ok: Bool?
    public var fileName: String?
    public var isImage: Bool?
    public var skipped: Bool?
    public var lines: [RemoteFormLine]?

    enum CodingKeys: String, CodingKey {
        case id, kind, date, origin, reply, text, ok, skipped, lines
        case fileName = "file_name"
        case isImage = "is_image"
    }

    public init(id: String, kind: String, date: Date? = nil, origin: String? = nil, reply: RemoteChatReply? = nil, text: String? = nil,
                ok: Bool? = nil, fileName: String? = nil, isImage: Bool? = nil, skipped: Bool? = nil, lines: [RemoteFormLine]? = nil) {
        self.id = id; self.kind = kind; self.date = date; self.origin = origin; self.reply = reply; self.text = text; self.ok = ok
        self.fileName = fileName; self.isImage = isImage; self.skipped = skipped; self.lines = lines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        // A date this app cannot read must not hide the message.
        date = try? c.decodeIfPresent(Date.self, forKey: .date)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        reply = try? c.decodeIfPresent(RemoteChatReply.self, forKey: .reply)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        isImage = try c.decodeIfPresent(Bool.self, forKey: .isImage)
        skipped = try c.decodeIfPresent(Bool.self, forKey: .skipped)
        lines = try? c.decodeIfPresent([RemoteFormLine].self, forKey: .lines)
    }

    public var row: RemoteChatRow {
        switch kind {
        case "user": return .user(text ?? "")
        case "assistant": return .assistant(text ?? "")
        case "tool": return .tool(text ?? "", ok: ok)
        case "error": return .error(text ?? "")
        case "screenshot": return .attachment(fileName: fileName ?? "file", isImage: isImage ?? true)
        case "form": return .form(message: text ?? "", skipped: skipped ?? false, lines: lines ?? [])
        case "notice": return .notice(text ?? "")
        default: return .unsupported(text ?? "")
        }
    }

    /// True for a message the user can reply to: what a person or the agent wrote.
    public var canReply: Bool { kind == "user" || kind == "assistant" }
}

public struct RemoteApproval: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public init(id: String, title: String, detail: String = "") { self.id = id; self.title = title; self.detail = detail }
}

public struct RemoteFormOption: Codable, Equatable, Hashable, Sendable {
    public var value: String
    public var title: String
    public var detail: String
    public init(value: String, title: String, detail: String = "") { self.value = value; self.title = title; self.detail = detail }
}

public struct RemoteFormField: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var required: Bool
    /// `single`, `multi`, `text`, `number` or `boolean`.
    public var type: String
    public var integer: Bool?
    public var options: [RemoteFormOption]?

    public init(id: String, title: String = "", detail: String = "", required: Bool = false, type: String, integer: Bool? = nil, options: [RemoteFormOption]? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.required = required; self.type = type; self.integer = integer; self.options = options
    }
}

/// What has been entered for a field: a string (a choice, text or a number), a list of choices or a yes or no.
public enum RemoteFormAnswer: Codable, Equatable, Hashable, Sendable {
    case text(String)
    case list([String])
    case flag(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let flag = try? c.decode(Bool.self) { self = .flag(flag) }
        else if let list = try? c.decode([String].self) { self = .list(list) }
        else { self = .text(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let text): try c.encode(text)
        case .list(let list): try c.encode(list)
        case .flag(let flag): try c.encode(flag)
        }
    }
}

public struct RemoteForm: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var message: String
    public var fields: [RemoteFormField]
    public var answers: [String: RemoteFormAnswer]
    public var canSubmit: Bool

    enum CodingKeys: String, CodingKey {
        case id, message, fields, answers
        case canSubmit = "can_submit"
    }

    public init(id: String, message: String, fields: [RemoteFormField], answers: [String: RemoteFormAnswer] = [:], canSubmit: Bool = false) {
        self.id = id; self.message = message; self.fields = fields; self.answers = answers; self.canSubmit = canSubmit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        fields = try c.decodeIfPresent([RemoteFormField].self, forKey: .fields) ?? []
        answers = try c.decodeIfPresent([String: RemoteFormAnswer].self, forKey: .answers) ?? [:]
        canSubmit = try c.decodeIfPresent(Bool.self, forKey: .canSubmit) ?? false
    }

    /// The fields grouped into pages, one page per question, the same way the Mac groups them.
    public var pages: [[RemoteFormField]] {
        ElicitationPaging.pages(ids: fields.map(\.id)).map { $0.map { fields[$0] } }
    }

    /// The first page with a required field that has no answer, or nil when every required field is answered.
    /// `typed` holds text that was entered but not sent yet and wins over `answers`.
    public func firstIncompletePage(typed: [String: String] = [:]) -> Int? {
        pages.firstIndex { page in
            page.contains { field in
                guard field.required else { return false }
                if let text = typed[field.id] { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                switch answers[field.id] {
                case .text(let text)?: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .list(let list)?: return list.isEmpty
                case .flag?: return false
                case nil: return true
                }
            }
        }
    }
}

/// A message waiting for the agent to finish its turn.
public struct RemoteQueued: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var fileCount: Int
    public var fromMac: Bool

    enum CodingKeys: String, CodingKey {
        case id, text
        case fileCount = "file_count"
        case fromMac = "from_mac"
    }

    public init(id: String, text: String, fileCount: Int = 0, fromMac: Bool = false) {
        self.id = id; self.text = text; self.fileCount = fileCount; self.fromMac = fromMac
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        fromMac = try c.decodeIfPresent(Bool.self, forKey: .fromMac) ?? false
    }
}

public struct RemoteChatAgent: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// What the chat settings offer, and what is chosen now.
public struct RemoteChatOptions: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// What the choice does, for a mode. Nil for an agent, model or folder.
        public var detail: String?
        public init(id: String, name: String, detail: String? = nil) { self.id = id; self.name = name; self.detail = detail }
    }

    public var agents: [Choice]
    public var models: [Choice]
    /// The Mac's recent folders. An id is the path the Mac takes back.
    public var folders: [Choice]
    /// The folder the chat works in, or nil for no project.
    public var folder: String?
    /// The permission modes the agent advertises, in the agent's order. Empty when the agent has none, or no session has started.
    public var modes: [Choice]
    /// The id of the mode in force, one of `modes`.
    public var mode: String?

    enum CodingKeys: String, CodingKey { case agents, models, folders, folder, modes, mode }

    public init(agents: [Choice] = [], models: [Choice] = [], folders: [Choice] = [], folder: String? = nil, modes: [Choice] = [], mode: String? = nil) {
        self.agents = agents; self.models = models; self.folders = folders; self.folder = folder; self.modes = modes; self.mode = mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = try c.decodeIfPresent(Lossy<Choice>.self, forKey: .agents)?.elements ?? []
        models = try c.decodeIfPresent(Lossy<Choice>.self, forKey: .models)?.elements ?? []
        folders = try c.decodeIfPresent(Lossy<Choice>.self, forKey: .folders)?.elements ?? []
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        modes = try c.decodeIfPresent(Lossy<Choice>.self, forKey: .modes)?.elements ?? []
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
    }
}

/// One change to the chat settings. Leave a field out to keep it.
public struct RemoteChatOptionsChange: Equatable, Sendable {
    public var agent: String?
    /// `.some(nil)` returns to the agent's default model.
    public var model: String??
    public var folder: String?
    public var noProject = false
    /// The id of one of the agent's modes.
    public var mode: String?

    public init(agent: String? = nil, model: String?? = nil, folder: String? = nil, noProject: Bool = false, mode: String? = nil) {
        self.agent = agent; self.model = model; self.folder = folder; self.noProject = noProject; self.mode = mode
    }

    var json: [String: Any] {
        var body: [String: Any] = [:]
        if let agent { body["agent"] = agent }
        if let model { body["model"] = model ?? NSNull() }
        if let folder { body["folder"] = folder }
        if noProject { body["no_project"] = true }
        if let mode { body["mode"] = mode }
        return body
    }
}

/// A list that skips an element that cannot be decoded instead of failing the whole list.
struct Lossy<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) { result.append(element) } else { _ = try? container.decode(DiscardedValue.self) }
        }
        elements = result
    }

    private struct DiscardedValue: Decodable {}
}

/// The answer to a read that sent the ETag of the chat the phone saved: the Mac's `304` (nothing changed), or the chat and its new ETag.
public enum ChatRead: Equatable, Sendable {
    case notModified
    case snapshot(RemoteChatSnapshot, etag: String?)
}

/// `GET /v1/chat/current`.
public struct RemoteChatSnapshot: Codable, Equatable, Sendable {
    public var threadID: String?
    public var title: String
    /// `idle`, `running`, `done` or `failed`.
    public var state: String
    public var running: Bool
    public var activity: String?
    /// When the running turn started, so the phone shows the same elapsed time the Mac does.
    public var runStarted: Date?
    public var folderLabel: String
    public var agent: RemoteChatAgent
    public var model: String?
    /// Something only the Mac can do, such as choosing a folder or signing in.
    public var notice: String?
    public var items: [RemoteChatItem]
    /// Whether older messages exist before `items`. Set only for a paged read; nil from a Mac that sends the whole thread.
    public var hasMore: Bool?
    /// Where this answer stands in the Mac's event stream: the launch (`epoch`) and the last event (`seq`). A later read sends them as
    /// `epoch` and `after` and gets only what changed. Nil from a Mac that does not send them.
    public var epoch: String?
    public var seq: Int?
    /// True when `items` holds only the messages that changed after the cursor sent, not a page of the thread.
    public var delta: Bool?
    /// True when the Mac could not honour the cursor and `items` is the newest page, as for a read with no cursor.
    public var reset: Bool?
    public var approvals: [RemoteApproval]
    public var forms: [RemoteForm]
    public var queue: [RemoteQueued]
    public var options: RemoteChatOptions

    enum CodingKeys: String, CodingKey {
        case title, state, running, activity, agent, model, notice, items, approvals, forms, queue, options, epoch, seq, delta, reset
        case runStarted = "run_started"
        case threadID = "thread_id"
        case folderLabel = "folder_label"
        case hasMore = "has_more"
    }

    public init(threadID: String? = nil, title: String = "New chat", state: String = "idle", running: Bool = false, activity: String? = nil,
                folderLabel: String = "demo-app", agent: RemoteChatAgent = RemoteChatAgent(id: "claude", name: "Claude Code"), model: String? = nil,
                runStarted: Date? = nil, notice: String? = nil, items: [RemoteChatItem] = [], approvals: [RemoteApproval] = [], forms: [RemoteForm] = [], queue: [RemoteQueued] = [],
                options: RemoteChatOptions = RemoteChatOptions()) {
        self.options = options
        self.threadID = threadID; self.title = title; self.state = state; self.running = running; self.activity = activity
        self.runStarted = runStarted
        self.folderLabel = folderLabel; self.agent = agent; self.model = model; self.notice = notice; self.items = items
        self.approvals = approvals; self.forms = forms; self.queue = queue
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        activity = try c.decodeIfPresent(String.self, forKey: .activity)
        runStarted = try? c.decodeIfPresent(Date.self, forKey: .runStarted)
        folderLabel = try c.decodeIfPresent(String.self, forKey: .folderLabel) ?? ""
        agent = try c.decodeIfPresent(RemoteChatAgent.self, forKey: .agent) ?? RemoteChatAgent(id: "", name: "Agent")
        model = try c.decodeIfPresent(String.self, forKey: .model)
        notice = try c.decodeIfPresent(String.self, forKey: .notice)
        items = try c.decodeIfPresent(Lossy<RemoteChatItem>.self, forKey: .items)?.elements ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore)
        epoch = try c.decodeIfPresent(String.self, forKey: .epoch)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        delta = try c.decodeIfPresent(Bool.self, forKey: .delta)
        reset = try c.decodeIfPresent(Bool.self, forKey: .reset)
        approvals = try c.decodeIfPresent(Lossy<RemoteApproval>.self, forKey: .approvals)?.elements ?? []
        forms = try c.decodeIfPresent(Lossy<RemoteForm>.self, forKey: .forms)?.elements ?? []
        queue = try c.decodeIfPresent(Lossy<RemoteQueued>.self, forKey: .queue)?.elements ?? []
        options = (try? c.decodeIfPresent(RemoteChatOptions.self, forKey: .options)) ?? RemoteChatOptions()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(threadID, forKey: .threadID)
        try c.encode(title, forKey: .title)
        try c.encode(state, forKey: .state)
        try c.encode(running, forKey: .running)
        try c.encodeIfPresent(activity, forKey: .activity)
        try c.encodeIfPresent(runStarted, forKey: .runStarted)
        try c.encode(folderLabel, forKey: .folderLabel)
        try c.encode(agent, forKey: .agent)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(notice, forKey: .notice)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(hasMore, forKey: .hasMore)
        try c.encodeIfPresent(epoch, forKey: .epoch)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encodeIfPresent(delta, forKey: .delta)
        try c.encodeIfPresent(reset, forKey: .reset)
        try c.encode(approvals, forKey: .approvals)
        try c.encode(forms, forKey: .forms)
        try c.encode(queue, forKey: .queue)
        try c.encode(options, forKey: .options)
    }
}

/// A saved thread in the list.
public struct RemoteChatThread: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var folderLabel: String
    public var updated: Date
    public var agent: String
    public var automationName: String?
    public var voice: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, updated, agent, voice
        case folderLabel = "folder_label"
        case automationName = "automation_name"
    }

    public init(id: String, title: String, folderLabel: String = "", updated: Date = Date(timeIntervalSince1970: 1_700_000_000), agent: String = "claude",
                automationName: String? = nil, voice: Bool? = nil) {
        self.id = id; self.title = title; self.folderLabel = folderLabel; self.updated = updated; self.agent = agent
        self.automationName = automationName; self.voice = voice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Chat"
        folderLabel = try c.decodeIfPresent(String.self, forKey: .folderLabel) ?? ""
        updated = try c.decode(Date.self, forKey: .updated)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        automationName = try c.decodeIfPresent(String.self, forKey: .automationName)
        voice = try c.decodeIfPresent(Bool.self, forKey: .voice)
    }
}

public struct ChatThreadListResponse: Codable, Equatable, Sendable {
    public var threads: [RemoteChatThread]
    public init(threads: [RemoteChatThread]) { self.threads = threads }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = try c.decodeIfPresent(Lossy<RemoteChatThread>.self, forKey: .threads)?.elements ?? []
    }

    enum CodingKeys: String, CodingKey { case threads }
}

/// `GET /v1/chat/threads/:id`: a thread with its items, to read.
public struct RemoteChatThreadDetail: Codable, Equatable, Sendable {
    public var thread: RemoteChatThread
    public var items: [RemoteChatItem]

    public init(thread: RemoteChatThread, items: [RemoteChatItem]) { self.thread = thread; self.items = items }

    public init(from decoder: Decoder) throws {
        thread = try RemoteChatThread(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent(Lossy<RemoteChatItem>.self, forKey: .items)?.elements ?? []
    }

    public func encode(to encoder: Encoder) throws {
        try thread.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
    }

    enum CodingKeys: String, CodingKey { case items }
}

/// What a message went into: `sent` started a turn, `queued` waits for the running one, `to_job` went to a background job.
public struct RemoteSendResult: Codable, Equatable, Sendable {
    public var outcome: String
    public init(outcome: String) { self.outcome = outcome }
}

public struct RemoteUpload: Codable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    /// The name the file has on the Mac, which a `screenshot` item shows as its `file_name`. It lets the phone match its own photo.
    public var storedName: String?
    public var bytes: Int

    enum CodingKeys: String, CodingKey {
        case id, bytes
        case fileName = "file_name"
        case storedName = "stored_name"
    }

    public init(id: String, fileName: String, storedName: String? = nil, bytes: Int) {
        self.id = id; self.fileName = fileName; self.storedName = storedName; self.bytes = bytes
    }
}

/// The quote a message carries: the item it answers, and the part the user selected when they did not mean all of it.
public struct RemoteReplyRef: Equatable, Hashable, Sendable {
    public var itemID: String
    public var selectionText: String?
    public init(itemID: String, selectionText: String? = nil) { self.itemID = itemID; self.selectionText = selectionText }
}
