import Foundation

/// Files a paired phone uploaded to send with a chat message. The bytes go to disk under `<directory>/<device id>/` and the phone gets an
/// id. An id works for the device that uploaded it, until a message uses it or the Mac app quits. The files stay on disk.
@MainActor
final class RemoteUploads {
    /// The most one upload may carry.
    nonisolated static let maxBytes = 20 << 20

    let directory: URL
    private var entries: [String: (device: String, url: URL)] = [:]

    init(directory: URL = Paths.root.appendingPathComponent("remote/files")) {
        self.directory = directory
    }

    /// The last path component of what the phone called the file, so it cannot choose where the file lands.
    static func safeName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent.filter { !$0.isNewline && $0 != "\0" }
        if name.isEmpty || name == "." || name == ".." { return "file" }
        return String(name.prefix(100))
    }

    /// Writes the file off the main actor, so a 20 MiB photo does not stall the Mac's UI, then records the id.
    func save(_ data: Data, fileName: String, device: String) async throws -> (id: String, name: String, stored: String) {
        let folder = directory.appendingPathComponent(device)
        let name = Self.safeName(fileName)
        let id = UUID().uuidString
        let stored = "\(id.prefix(8))-\(name)"
        let url = folder.appendingPathComponent(stored)
        try await Task.detached {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
        }.value
        entries[id] = (device, url)
        return (id, name, stored)
    }

    /// The files for these ids, or a 404 when one is unknown or belongs to another device.
    func files(_ ids: [String], device: String) throws -> [URL] {
        try ids.map { id in
            guard let entry = entries[id], entry.device == device, FileManager.default.fileExists(atPath: entry.url.path) else {
                throw RemoteFailure(status: 404, code: "not_found", message: "that upload is not available")
            }
            return entry.url
        }
    }

    func forget(_ ids: [String]) { for id in ids { entries[id] = nil } }
}

/// The chat routes: the one shared chat as JSON objects with snake_case keys and ISO 8601 dates. Every call goes through `IronPetAPI.chat`
/// with the origin `ios` and the device id, so the Mac transcript marks the message and the chat does not read the turn aloud.
///
/// `kind` of an item is an open string: `user`, `assistant`, `tool`, `error`, `screenshot`, `form`. A phone shows a kind it does not know
/// as a plain row with the item's `text`, so a new kind needs no change on the phone.
@MainActor
struct RemoteChat {
    let api: IronPetAPI
    /// The device that calls. Its id names the origin of a chat message.
    let device: String
    let uploads: RemoteUploads

    private var origin: ChatOrigin { ChatOrigin(client: "ios", ref: device) }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    // MARK: Reading

    func current() async -> [String: Any] {
        let snapshot = api.chat.snapshot()
        let status = snapshot.status, options = snapshot.options
        var object: [String: Any] = [
            "title": status.title, "state": status.state, "running": status.running, "folder_label": options.folderLabel,
            "agent": ["id": options.agent.id, "name": options.agent.name],
            "items": snapshot.messages.map(Self.json), "approvals": snapshot.approvals.map(Self.json),
            "forms": snapshot.forms.map(Self.json), "queue": snapshot.queue.map(Self.json)
        ]
        if let id = status.threadID { object["thread_id"] = id }
        if let model = options.model { object["model"] = model }
        if let activity = status.activity { object["activity"] = activity }
        if let started = status.runStartedAt { object["run_started"] = Self.iso(started) }
        if let notice = Self.notice(options) { object["notice"] = notice }
        return object
    }

    /// What the Mac chat waits for that only the Mac can do.
    private static func notice(_ options: ChatOptions) -> String? {
        if options.needsFolder { return "Choose a folder for this chat on the Mac." }
        if let offer = options.runtimeOffer { return "\(offer) needs a runtime. Install it on the Mac." }
        if !options.signInMethods.isEmpty { return "\(options.agent.name) needs you to sign in. Do it on the Mac." }
        return nil
    }

    func message(_ id: String) async throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { throw Self.unknownMessage }
        return Self.json(try await api.chat.message(uuid))
    }

    private static var unknownMessage: RemoteFailure { RemoteFailure(status: 404, code: "not_found", message: "no message with this id") }

    func threads() async -> [String: Any] { ["threads": await api.chat.threads().map(Self.json)] }

    func thread(_ id: String) async throws -> [String: Any] {
        let found = try await api.chat.thread(id)
        var object = Self.json(found.info)
        object["items"] = found.items.map(Self.json)
        return object
    }

    // MARK: Sending

    /// `{text, upload_ids?, reply?: {item_id, selection_text?}}`.
    func send(_ body: [String: Any]) async throws -> [String: Any] {
        let text = (body["text"] as? String ?? "")
        let ids = body["upload_ids"] as? [String] ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ids.isEmpty else { throw RemoteFailure.invalid("the message is empty") }
        var reply: ChatReply?
        if let quote = body["reply"] as? [String: Any] {
            guard let itemID = (quote["item_id"] as? String).flatMap(UUID.init(uuidString:)) else { throw RemoteFailure.invalid("reply needs an item_id") }
            reply = try await replyTo(itemID, selection: quote["selection_text"] as? String)
        }
        let files = try uploads.files(ids, device: device)
        let result = try await api.chat.send(SendChatRequest(text: text, origin: origin, files: files, reply: reply))
        uploads.forget(ids)
        return ["outcome": Self.name(result.outcome)]
    }

    /// The quote of a user or assistant message, as the Mac builds it. A tool step, a screenshot or an error cannot be replied to.
    private func replyTo(_ id: UUID, selection: String?) async throws -> ChatReply {
        let item: ChatItem
        do { item = try await api.chat.message(id) } catch { throw RemoteFailure.invalid("the message to reply to is not in this chat") }
        let sender: String, text: String, fromUser: Bool
        switch item.kind {
        case .user(let value): sender = "You"; text = value; fromUser = true
        case .assistant(let value): sender = api.settings.config.pet.name; text = value; fromUser = false
        default: throw RemoteFailure.invalid("this message cannot be replied to")
        }
        let trimmed = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed?.isEmpty == false ? trimmed : nil
        return ChatReply(itemID: id, sender: sender, text: selected ?? text, date: item.date, selection: selected == nil ? nil : true, fromUser: fromUser)
    }

    func stop() async -> [String: Any] {
        _ = await api.chat.stop(keepDraft: true)
        return ["stopped": true]
    }

    // MARK: Threads

    /// A running turn or a waiting question blocks it, since opening a thread would stop them.
    private func requireIdle() async throws {
        let status = await api.chat.status()
        if status.running { throw RemoteFailure(status: 409, code: "conflict", message: "The agent is working. Stop it first, or wait for it to finish.") }
        if status.pendingApprovals > 0 || status.pendingForms > 0 {
            throw RemoteFailure(status: 409, code: "conflict", message: "The agent is waiting for an answer. Answer it first.")
        }
    }

    func open(_ id: String) async throws -> [String: Any] {
        try await requireIdle()
        try await api.chat.openThread(id)
        return ["opened": id]
    }

    func newChat() async throws -> [String: Any] {
        try await requireIdle()
        await api.chat.newChat()
        return ["opened": true]
    }

    // MARK: Approvals and forms

    func decide(_ id: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let allow = body["allow"] as? Bool else { throw RemoteFailure.invalid("allow must be true or false") }
        guard let uuid = UUID(uuidString: id) else { throw RemoteFailure(status: 404, code: "not_found", message: "that approval is no longer waiting") }
        try await api.chat.decide(DecideApprovalRequest(id: uuid, allow: allow))
        return ["allowed": allow]
    }

    private func formID(_ id: String) throws -> UUID {
        guard let uuid = UUID(uuidString: id) else { throw RemoteFailure(status: 404, code: "not_found", message: "that question is no longer waiting") }
        return uuid
    }

    /// `{answers?: {field: value}}`. A string answers a single choice, text or number field, a list a multiple choice, a bool a yes or no
    /// field, and null clears the answer.
    func answer(_ id: String, _ body: [String: Any]) async throws -> [String: Any] {
        let uuid = try formID(id)
        try await apply(body["answers"], to: uuid)
        return ["answered": true]
    }

    func submit(_ id: String, _ body: [String: Any]) async throws -> [String: Any] {
        let uuid = try formID(id)
        try await apply(body["answers"], to: uuid)
        try await api.chat.submitForm(uuid)
        return ["submitted": true]
    }

    func skip(_ id: String) async throws -> [String: Any] {
        try await api.chat.skipForm(try formID(id))
        return ["skipped": true]
    }

    private func apply(_ raw: Any?, to id: UUID) async throws {
        guard let raw, !(raw is NSNull) else { return }
        guard let answers = raw as? [String: Any] else { throw RemoteFailure.invalid("answers must be an object") }
        guard let form = await api.chat.forms().first(where: { $0.id == id }) else {
            throw RemoteFailure(status: 404, code: "not_found", message: "that question is no longer waiting")
        }
        var parsed: [(String, ElicitationValue?)] = []
        for (name, value) in answers {
            guard let field = form.form.fields.first(where: { $0.id == name }) else { throw RemoteFailure.invalid("no field \"\(name)\"") }
            parsed.append((name, try Self.value(value, for: field)))
        }
        for (name, value) in parsed { try await api.chat.answerForm(AnswerFormRequest(id: id, field: name, value: value)) }
    }

    private static func value(_ raw: Any, for field: ElicitationField) throws -> ElicitationValue? {
        if raw is NSNull { return nil }
        let wrong = RemoteFailure.invalid("the answer to \"\(field.id)\" has the wrong type")
        switch field.kind {
        case .single:
            guard let text = raw as? String else { throw wrong }
            return .one(text)
        case .multi:
            guard let list = raw as? [String] else { throw wrong }
            return .many(list)
        case .text, .number:
            if let text = raw as? String { return .text(text) }
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return .text(number.stringValue) }
            throw wrong
        case .boolean:
            guard let flag = raw as? Bool else { throw wrong }
            return .flag(flag)
        }
    }

    // MARK: JSON

    private static func name(_ outcome: ChatSendOutcome) -> String {
        switch outcome {
        case .ignored: return "ignored"
        case .sent: return "sent"
        case .queued: return "queued"
        case .toJob: return "to_job"
        case .needsFolder: return "needs_folder"
        }
    }

    static func json(_ item: ChatItem) -> [String: Any] {
        var object: [String: Any] = ["id": item.id.uuidString]
        if let date = item.date { object["date"] = iso(date) }
        if let origin = item.origin { object["origin"] = origin }
        if let reply = item.reply { object["reply"] = json(reply) }
        switch item.kind {
        case .user(let text): object["kind"] = "user"; object["text"] = text
        case .assistant(let text): object["kind"] = "assistant"; object["text"] = text
        case .error(let text): object["kind"] = "error"; object["text"] = text
        case .tool(let text, let ok):
            object["kind"] = "tool"
            object["text"] = text
            if let ok { object["ok"] = ok }
        case .screenshot(let path):
            // The file name only: the folder it sits in is the Mac's business.
            object["kind"] = "screenshot"
            object["file_name"] = (path as NSString).lastPathComponent
            object["is_image"] = ImageIntake.isImageFile(URL(fileURLWithPath: path))
        case .form(let record):
            object["kind"] = "form"
            object["text"] = record.message
            object["skipped"] = record.skipped
            object["lines"] = record.lines.map { ["question": $0.question, "answer": $0.answer] }
        }
        return object
    }

    private static func json(_ reply: ChatReply) -> [String: Any] {
        var object: [String: Any] = ["item_id": reply.itemID.uuidString, "sender": reply.sender, "text": reply.text]
        if let date = reply.date { object["date"] = iso(date) }
        if reply.selection == true { object["selection"] = true }
        if let fromUser = reply.fromUser { object["from_user"] = fromUser }
        return object
    }

    private static func json(_ approval: ChatApprovalInfo) -> [String: Any] {
        ["id": approval.id.uuidString, "title": approval.title, "detail": approval.detail]
    }

    private static func json(_ queued: ChatQueuedInfo) -> [String: Any] {
        var object: [String: Any] = ["id": queued.id.uuidString, "text": queued.text, "file_count": queued.files.count, "from_mac": queued.fromMac]
        if let reply = queued.reply { object["reply"] = json(reply) }
        return object
    }

    private static func json(_ thread: ChatThreadInfo) -> [String: Any] {
        var object: [String: Any] = ["id": thread.id, "title": thread.title, "folder_label": (thread.workspace as NSString).lastPathComponent,
                                     "updated": iso(thread.updatedAt), "agent": thread.agent]
        if let name = thread.automationName { object["automation_name"] = name }
        if thread.voice == true { object["voice"] = true }
        return object
    }

    private static func json(_ form: ChatFormInfo) -> [String: Any] {
        var answers: [String: Any] = [:]
        for (name, value) in form.answers {
            switch value {
            case .one(let text), .text(let text): answers[name] = text
            case .many(let list): answers[name] = list
            case .flag(let on): answers[name] = on
            }
        }
        return ["id": form.id.uuidString, "message": form.form.message, "fields": form.form.fields.map(json), "answers": answers,
                "can_submit": form.form.canSubmit(form.answers)]
    }

    private static func json(_ field: ElicitationField) -> [String: Any] {
        var object: [String: Any] = ["id": field.id, "title": field.title, "detail": field.detail, "required": field.required]
        func options(_ list: [ElicitationOption]) -> [[String: Any]] { list.map { ["value": $0.value, "title": $0.title, "detail": $0.detail] } }
        switch field.kind {
        case .single(let list): object["type"] = "single"; object["options"] = options(list)
        case .multi(let list): object["type"] = "multi"; object["options"] = options(list)
        case .text: object["type"] = "text"
        case .number(let integer): object["type"] = "number"; object["integer"] = integer
        case .boolean: object["type"] = "boolean"
        }
        return object
    }
}

/// Lets at most one `chat.item` event per message through each interval, and always the last one after a quiet interval, so a streamed
/// reply costs the phone ten reads a second and its final text is never lost. Other events pass at once.
@MainActor
final class RemoteEventThrottle {
    private let interval: Duration
    private let deliver: (APIEvent) -> Void
    private var lastSent: [String: ContinuousClock.Instant] = [:]
    private var waiting: [String: APIEvent] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    init(interval: Duration = .milliseconds(100), deliver: @escaping (APIEvent) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func push(_ event: APIEvent) {
        guard event.kind == .chatItem, let id = event.id else { return deliver(event) }
        let now = ContinuousClock.now
        if timers[id] == nil, lastSent[id].map({ now - $0 >= interval }) ?? true {
            lastSent[id] = now
            return deliver(event)
        }
        waiting[id] = event
        guard timers[id] == nil, let last = lastSent[id] else { return }
        timers[id] = Task { [weak self, interval] in
            try? await Task.sleep(until: last + interval, clock: ContinuousClock())
            guard !Task.isCancelled else { return }
            self?.flush(id)
        }
    }

    private func flush(_ id: String) {
        timers[id] = nil
        guard let event = waiting.removeValue(forKey: id) else { return }
        lastSent[id] = ContinuousClock.now
        deliver(event)
    }

    func cancel() {
        for timer in timers.values { timer.cancel() }
        timers = [:]
        waiting = [:]
    }
}
