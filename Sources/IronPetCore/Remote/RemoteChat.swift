import Foundation

/// Files a paired phone uploaded to send with a chat message. The bytes go to disk under `<directory>/<device id>/` and the phone gets an
/// id. An id works for the device that uploaded it, until a message uses it or the Mac app quits. The files stay on disk.
@MainActor
package final class RemoteUploads {
    /// The most one upload may carry.
    package nonisolated static let maxBytes = 20 << 20

    package let directory: URL
    private var entries: [String: (device: String, url: URL)] = [:]

    package init(directory: URL = Paths.root.appendingPathComponent("remote/files")) {
        self.directory = directory
    }

    /// The last path component of what the phone called the file, so it cannot choose where the file lands.
    package static func safeName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent.filter { !$0.isNewline && $0 != "\0" }
        if name.isEmpty || name == "." || name == ".." { return "file" }
        return String(name.prefix(100))
    }

    /// Writes the file off the main actor, so a 20 MiB photo does not stall the Mac's UI, then records the id.
    package func save(_ data: Data, fileName: String, device: String) async throws -> (id: String, name: String, stored: String) {
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
    package func files(_ ids: [String], device: String) throws -> [URL] {
        try ids.map { id in
            guard let entry = entries[id], entry.device == device, FileManager.default.fileExists(atPath: entry.url.path) else {
                throw RemoteFailure(status: 404, code: "not_found", message: "that upload is not available")
            }
            return entry.url
        }
    }

    package func forget(_ ids: [String]) { for id in ids { entries[id] = nil } }
}

/// The chat routes: the one shared chat as JSON objects with snake_case keys and ISO 8601 dates. Every call goes through `IronPetAPI.chat`
/// with the origin `ios` and the device id, so the Mac transcript marks the message and the chat does not read the turn aloud.
///
/// `kind` of an item is an open string: `user`, `assistant`, `tool`, `error`, `screenshot`, `form`. A phone shows a kind it does not know
/// as a plain row with the item's `text`, so a new kind needs no change on the phone.
@MainActor
package struct RemoteChat {
    package init(api: IronPetAPI, device: String, uploads: RemoteUploads) {
        self.api = api
        self.device = device
        self.uploads = uploads
        self.chat = api.chat
    }

    /// The chat of one agent. Nil is agent 1. An id no agent has is 404, and an agent that is not running is 503.
    package init(api: IronPetAPI, device: String, uploads: RemoteUploads, agentId: String?) throws {
        self.api = api
        self.device = device
        self.uploads = uploads
        self.chat = try api.chat(for: agentId)
    }

    /// The chat every call here reads and writes.
    private let chat: ChatAPI

    package let api: IronPetAPI
    /// The device that calls. Its id names the origin of a chat message.
    package let device: String
    package let uploads: RemoteUploads

    private var origin: ChatOrigin { ChatOrigin.ios(device: device) }
    private nonisolated static func iso(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle()) }

    // MARK: Reading

    /// The most messages one read returns when the phone sends no `limit`. Phones from before paging asked for the whole thread, which
    /// reached several MB on a long chat. They show the newest `defaultLimit` messages, and `has_more` tells a newer phone that older ones exist.
    package nonisolated static let defaultLimit = 200

    /// Called with each build of the chat body, off the main actor. Tests count builds and slow them down with it.
    // Safe: tests set it before a request and clear it after, and production code never writes it.
    package nonisolated(unsafe) static var buildHook: (@Sendable () -> Void)?

    /// A version of what `current` would answer, cheap to read: it changes with every chat event, so a phone that holds the same value
    /// holds the same chat. `limit` and `before` change the page, so they are part of it.
    package func version(limit: Int?, before: String?) -> String {
        let page = (before ?? "-").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x"
        return "\(api.events.epoch.prefix(8))-\(api.events.chatVersion)-\(limit.map(String.init) ?? "-")-\(page)"
    }

    /// The chat's state at this moment. It copies arrays and builds nothing, so it is the only part of a read that needs the main actor.
    package func snapshot() -> ChatSnapshot { chat.snapshot() }

    /// The chat as the phone shows it, as JSON bytes. With `limit`, `items` is the newest `limit` visible messages, or the `limit` before
    /// the message `before` names, and `has_more` says whether older ones exist. Without `limit` the newest `defaultLimit` come back.
    /// An unknown `before` gives no items, so a phone never merges a page it cannot place. It runs off the main actor.
    package nonisolated static func body(_ snapshot: ChatSnapshot, limit: Int?, before: String?, sync: Sync? = nil) -> Data {
        buildHook?()
        var object = page(snapshot, limit: limit, before: before, changed: sync?.changed)
        if let sync {
            object["epoch"] = sync.epoch
            object["seq"] = sync.seq
            if sync.changed != nil { object["delta"] = true }
            if sync.reset { object["reset"] = true }
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    package func current(limit: Int? = nil, before: String? = nil) async -> [String: Any] {
        Self.page(chat.snapshot(), limit: limit, before: before)
    }

    /// Where the chat stands in the event stream, and what changed since the phone's cursor. Read it in the same main actor turn as
    /// `snapshot()`, so the cursor and the messages agree.
    package struct Sync {
        package let epoch: String
        package let seq: Int
        /// The ids of the messages that changed after the phone's cursor, or nil when the phone must read a page again.
        package let changed: Set<String>?
        /// True when the phone sent a cursor the Mac could not honour: another launch, a gap in the buffer, or a change with no id.
        package let reset: Bool
    }

    /// With `after` (the `seq` of an earlier answer) and the `epoch` it came with, the messages that changed since then. A cursor from
    /// another launch, one older than the event buffer, or a change that names no message (a removal or a reset) gives `reset`, and
    /// the read answers the newest page as if no cursor was sent.
    package func sync(after: Int?, epoch: String?) -> Sync {
        let bus = api.events
        guard let after else { return Sync(epoch: bus.epoch, seq: bus.lastSeq, changed: nil, reset: false) }
        let missed = bus.replay(after: after)
        var ids = Set<String>()
        var complete = epoch == bus.epoch && !missed.gap
        for event in missed.events where event.kind == .chatItem {
            if let id = event.id { ids.insert(id) } else { complete = false }
        }
        return Sync(epoch: bus.epoch, seq: bus.lastSeq, changed: complete ? ids : nil, reset: !complete)
    }

    package nonisolated static func page(_ snapshot: ChatSnapshot, limit: Int?, before: String?, changed: Set<String>? = nil) -> [String: Any] {
        if let changed {
            // Only the messages that changed, in thread order. A message that is gone has nothing to send, and the phone drops it
            // when it reads a page again.
            let items = snapshot.messages.filter { changed.contains($0.id.uuidString) && isVisible($0) }
            return build(snapshot, items, hasMore: false, includeHasMore: false)
        }
        let size = limit ?? defaultLimit
        let messages = snapshot.messages
        // Walk back from the end so a read of the newest page does not touch the older thousands.
        var end = messages.count
        if let before {
            guard let index = messages.firstIndex(where: { $0.id.uuidString == before }) else { return build(snapshot, [], hasMore: false) }
            end = index
        }
        var page: [ChatItem] = []
        var start = end
        while start > 0, page.count < size {
            start -= 1
            if isVisible(messages[start]) { page.append(messages[start]) }
        }
        page.reverse()
        var hasMore = false
        while start > 0 { start -= 1; if isVisible(messages[start]) { hasMore = true; break } }
        return build(snapshot, page, hasMore: hasMore)
    }

    private nonisolated static func build(_ snapshot: ChatSnapshot, _ page: [ChatItem], hasMore: Bool, includeHasMore: Bool = true) -> [String: Any] {
        let status = snapshot.status, options = snapshot.options
        var object: [String: Any] = [
            "title": status.title, "state": status.state, "running": status.running, "folder_label": options.folderLabel,
            "agent": ["id": options.agent.id, "name": options.agent.name],
            "items": page.map(json), "approvals": snapshot.approvals.map(json),
            "forms": snapshot.forms.map(json), "queue": snapshot.queue.map(json)
        ]
        if includeHasMore { object["has_more"] = hasMore }
        if let id = status.threadID { object["thread_id"] = id }
        if let model = options.model { object["model"] = model }
        if let activity = status.activity { object["activity"] = activity }
        if let started = status.runStartedAt { object["run_started"] = iso(started) }
        if let notice = notice(options) { object["notice"] = notice }
        object["options"] = json(options)
        return object
    }

    /// What the chat settings sheet on the phone offers. A folder's `id` is its path, which `setOptions` accepts back.
    private nonisolated static func json(_ options: ChatOptions) -> [String: Any] {
        var object: [String: Any] = [
            "agents": options.agents.map { ["id": $0.id, "name": $0.name] },
            "models": options.models.map { ["id": $0.id, "name": $0.name] },
            "folders": options.recentFolders.map { ["id": $0, "name": ($0 as NSString).lastPathComponent] }
        ]
        // The modes the agent advertises, as the Mac's picker lists them, and the one in force. A client never invents a mode.
        if !options.modes.isEmpty {
            object["modes"] = options.modes.map { mode -> [String: Any] in
                var entry: [String: Any] = ["id": mode.id, "name": mode.name]
                if !mode.detail.isEmpty { entry["detail"] = mode.detail }
                return entry
            }
        }
        if let mode = options.mode { object["mode"] = mode }
        // No `folder` means no project, so the scratch folder the Mac uses for general questions is left out.
        if let folder = options.folder, folder != ChatSession.scratchWorkspace.path { object["folder"] = folder }
        return object
    }

    // MARK: Settings

    /// `{agent?, model?, folder?, no_project?, mode?}`, the same choices as the Mac's chat settings, applied through the same API.
    /// `model: null` returns to the agent's default. The agent, model and folder cannot change while a turn runs, as on the Mac, and the
    /// folder must be one the Mac chat already lists. Everything is checked before anything changes.
    package func setOptions(_ body: [String: Any]) async throws -> [String: Any] {
        let options = await chat.options()
        var agent: String?, folder: String?
        if let raw = body["agent"] {
            guard let id = raw as? String, options.agents.contains(where: { $0.id == id }) else { throw RemoteFailure.invalid("no such agent") }
            agent = id
        }
        let changesModel = body.keys.contains("model")
        let model = body["model"] as? String
        if changesModel, !(body["model"] is NSNull), model == nil { throw RemoteFailure.invalid("model must be a model id or null") }
        if let raw = body["folder"] {
            guard let path = raw as? String, options.recentFolders.contains(path) else { throw RemoteFailure.invalid("choose one of the Mac's recent folders") }
            folder = path
        }
        let noProject = body["no_project"] as? Bool == true
        if body["no_project"] != nil, body["no_project"] as? Bool == nil { throw RemoteFailure.invalid("no_project must be true or false") }
        if folder != nil, noProject { throw RemoteFailure.invalid("choose a folder or no project, not both") }
        var mode: String?
        if let raw = body["mode"] {
            guard let id = raw as? String, options.modes.contains(where: { $0.id == id }) else { throw RemoteFailure.invalid("choose one of the modes the agent offers") }
            mode = id
        }
        if let model {
            // A model belongs to an agent, so it is checked against the list of the agent that will run it.
            let target = agent ?? options.agent.id
            let offered = target == options.agent.id ? options.models.map(\.id) : AgentCatalog.agent(id: target).map { ChatSession.cachedModels(for: $0).map(\.id) } ?? []
            guard offered.contains(model) else { throw RemoteFailure.invalid("this agent does not offer that model") }
        }
        if agent != nil || changesModel || folder != nil || noProject {
            if await chat.status().running {
                throw RemoteFailure(status: 409, code: "conflict", message: "The agent is working. Stop it first, or wait for it to finish.")
            }
        }
        if let agent { try await chat.setAgent(agent) }
        if changesModel { await chat.setModel(model) }
        if let folder { try await chat.useFolder(folder) }
        if noProject { await chat.useNoProject() }
        if let mode { await chat.setMode(mode) }
        return ["changed": true]
    }

    /// What the Mac chat waits for that only the Mac can do.
    private nonisolated static func notice(_ options: ChatOptions) -> String? {
        if options.needsFolder { return "Choose a folder for this chat on the Mac." }
        if let offer = options.runtimeOffer { return "\(offer) needs a runtime. Install it on the Mac." }
        if !options.signInMethods.isEmpty { return "\(options.agent.name) needs you to sign in. Do it on the Mac." }
        return nil
    }

    package func message(_ id: String) async throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { throw Self.unknownMessage }
        return Self.json(try await chat.message(uuid))
    }

    /// The most bytes of one image the route sends. Uploads stop at 20 MiB, and a Mac screenshot is smaller than that.
    package nonisolated static let maxFileBytes = RemoteUploads.maxBytes

    /// The image behind a message of kind `screenshot`: a file the user attached on the Mac or a screenshot it took. The client names a
    /// message of the open chat, never a path, so the route can read only a file the chat already holds. A message that is not an
    /// image attachment, or whose file is gone, is a 404 with a reason the phone can show.
    package func file(_ id: String) async throws -> (data: Data, contentType: String, name: String) {
        guard let uuid = UUID(uuidString: id) else { throw Self.unknownMessage }
        let item = try await chat.message(uuid)
        guard case .screenshot(let path) = item.kind else {
            throw RemoteFailure(status: 404, code: "not_found", message: "this message has no attachment")
        }
        let url = URL(fileURLWithPath: path)
        guard FolderFileIntake.isImageFile(url) else {
            throw RemoteFailure(status: 404, code: "not_found", message: "this attachment is not an image")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard let size else { throw RemoteFailure(status: 404, code: "not_found", message: "the file is no longer on the Mac") }
        guard size <= Self.maxFileBytes else { throw RemoteFailure(status: 413, code: "too_large", message: "the image is too large to send to the phone") }
        let data = try await Task.detached { try Data(contentsOf: url) }.value
        return (data, RemoteResources.contentType(url.lastPathComponent), url.lastPathComponent)
    }

    /// The preview of a file a reply named. It may come only from the open chat's folder, where the agent works. The scratch folder of a
    /// general question is not one, and neither are the recent folders, which can be as wide as a home folder. See `RemoteFilePreview`.
    package func filePreview(path: String) async throws -> FilePreview {
        let options = await chat.options()
        var roots: [String] = []
        if let folder = options.folder, folder != ChatSession.scratchWorkspace.path { roots.append(folder) }
        let file = try RemoteFilePreview.resolve(path, roots: roots)
        return try await Task.detached { try RemoteFilePreview.read(file) }.value
    }

    private static var unknownMessage: RemoteFailure { RemoteFailure(status: 404, code: "not_found", message: "no message with this id") }

    package func threads() async -> [String: Any] { ["threads": await chat.threads().map(Self.json)] }

    /// The threads one agent owns, newest first. Nil is agent 1.
    package func threads(agentId: String?) async throws -> [String: Any] {
        ["threads": try await chat.threads(agentId: agentId).map(Self.json)]
    }

    package func thread(_ id: String) async throws -> [String: Any] {
        let found = try await chat.thread(id)
        var object = Self.json(found.info)
        object["items"] = found.items.filter(Self.isVisible).map(Self.json)
        return object
    }

    // MARK: Sending

    /// `{text, upload_ids?, reply?: {item_id, selection_text?}}`.
    package func send(_ body: [String: Any]) async throws -> [String: Any] {
        let text = (body["text"] as? String ?? "")
        let ids = body["upload_ids"] as? [String] ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ids.isEmpty else { throw RemoteFailure.invalid("the message is empty") }
        var reply: ChatReply?
        if let quote = body["reply"] as? [String: Any] {
            guard let itemID = (quote["item_id"] as? String).flatMap(UUID.init(uuidString:)) else { throw RemoteFailure.invalid("reply needs an item_id") }
            reply = try await replyTo(itemID, selection: quote["selection_text"] as? String)
        }
        let files = try uploads.files(ids, device: device)
        let result = try await chat.send(SendChatRequest(text: text, origin: origin, files: files, reply: reply))
        uploads.forget(ids)
        return ["outcome": Self.name(result.outcome)]
    }

    /// A message the phone sent over the event socket. The phone made `clientID`, so a second frame with the same id returns the first
    /// ack and sends nothing. `body` is the same object `send` takes.
    package func send(clientID: String, _ body: [String: Any], ledger: RemoteSendLedger) async throws -> RemoteSendAck {
        guard UUID(uuidString: clientID) != nil else { throw RemoteFailure.invalid("client_id must be a UUID") }
        return try await ledger.once(device: device, clientID: clientID) {
            let outcome = try await send(body)["outcome"] as? String ?? ChatSendOutcome.sent.rawValue
            // A message that started a turn is the newest user item. A queued one has no item until its turn comes.
            let itemID = outcome == ChatSendOutcome.sent.rawValue
                ? await chat.messages().last { if case .user = $0.kind { true } else { false } }?.id.uuidString : nil
            return RemoteSendAck(clientID: clientID, outcome: outcome, itemID: itemID, seq: api.events.lastSeq)
        }
    }

    /// The quote of a user or assistant message, as the Mac builds it. A tool step, a screenshot or an error cannot be replied to.
    private func replyTo(_ id: UUID, selection: String?) async throws -> ChatReply {
        let item: ChatItem
        do { item = try await chat.message(id) } catch { throw RemoteFailure.invalid("the message to reply to is not in this chat") }
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

    package func stop() async -> [String: Any] {
        _ = await chat.stop(keepDraft: true)
        return ["stopped": true]
    }

    // MARK: Threads

    /// A running turn or a waiting question blocks it, since opening a thread would stop them.
    private func requireIdle() async throws {
        let status = await chat.status()
        if status.running { throw RemoteFailure(status: 409, code: "conflict", message: "The agent is working. Stop it first, or wait for it to finish.") }
        if status.pendingApprovals > 0 || status.pendingForms > 0 {
            throw RemoteFailure(status: 409, code: "conflict", message: "The agent is waiting for an answer. Answer it first.")
        }
    }

    package func open(_ id: String) async throws -> [String: Any] {
        try await requireIdle()
        try await chat.openThread(id)
        return ["opened": id]
    }

    package func newChat() async throws -> [String: Any] {
        try await requireIdle()
        await chat.newChat()
        return ["opened": true]
    }

    // MARK: Approvals and forms

    package func decide(_ id: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let allow = body["allow"] as? Bool else { throw RemoteFailure.invalid("allow must be true or false") }
        guard let uuid = UUID(uuidString: id) else { throw RemoteFailure(status: 404, code: "not_found", message: "that approval is no longer waiting") }
        try await chat.decide(DecideApprovalRequest(id: uuid, allow: allow))
        return ["allowed": allow]
    }

    private func formID(_ id: String) throws -> UUID {
        guard let uuid = UUID(uuidString: id) else { throw RemoteFailure(status: 404, code: "not_found", message: "that question is no longer waiting") }
        return uuid
    }

    /// `{answers?: {field: value}}`. A string answers a single choice, text or number field, a list a multiple choice, a bool a yes or no
    /// field, and null clears the answer.
    package func answer(_ id: String, _ body: [String: Any]) async throws -> [String: Any] {
        let uuid = try formID(id)
        try await apply(body["answers"], to: uuid)
        return ["answered": true]
    }

    package func submit(_ id: String, _ body: [String: Any]) async throws -> [String: Any] {
        let uuid = try formID(id)
        try await apply(body["answers"], to: uuid)
        try await chat.submitForm(uuid)
        return ["submitted": true]
    }

    package func skip(_ id: String) async throws -> [String: Any] {
        try await chat.skipForm(try formID(id))
        return ["skipped": true]
    }

    private func apply(_ raw: Any?, to id: UUID) async throws {
        guard let raw, !(raw is NSNull) else { return }
        guard let answers = raw as? [String: Any] else { throw RemoteFailure.invalid("answers must be an object") }
        guard let form = await chat.forms().first(where: { $0.id == id }) else {
            throw RemoteFailure(status: 404, code: "not_found", message: "that question is no longer waiting")
        }
        var parsed: [(String, ElicitationValue?)] = []
        for (name, value) in answers {
            guard let field = form.form.fields.first(where: { $0.id == name }) else { throw RemoteFailure.invalid("no field \"\(name)\"") }
            parsed.append((name, try Self.value(value, for: field)))
        }
        for (name, value) in parsed { try await chat.answerForm(AnswerFormRequest(id: id, field: name, value: value)) }
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
            if let number = raw as? NSNumber, !number.isJSONBoolean { return .text(number.stringValue) }
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

    /// A notice with no text only carries metadata and draws nothing on the Mac.
    package nonisolated static func isVisible(_ item: ChatItem) -> Bool {
        if case .notice(let text) = item.kind { return !text.isEmpty }
        return true
    }

    /// The most text of one message a `chat.item` event carries. A longer message makes the phone read it with a GET.
    package nonisolated static let maxInlineTextBytes = 16 * 1024

    /// The message as the socket sends it inside a `chat.item` event, so the phone needs no read. Nil for a message the phone must
    /// read itself: one with a file or a form, or text over `maxInlineTextBytes`.
    package nonisolated static func inlineJSON(_ item: ChatItem) -> [String: Any]? {
        switch item.kind {
        case .user(let text), .assistant(let text), .error(let text), .tool(let text, _), .notice(let text):
            guard text.utf8.count <= maxInlineTextBytes else { return nil }
            return json(item)
        case .screenshot, .form: return nil
        }
    }

    package nonisolated static func json(_ item: ChatItem) -> [String: Any] {
        var object: [String: Any] = ["id": item.id.uuidString]
        if let date = item.date { object["date"] = iso(date) }
        if let origin = item.origin { object["origin"] = origin }
        if let reply = item.reply { object["reply"] = json(reply) }
        if let selection = item.selection { object["selection"] = json(selection) }
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
            object["is_image"] = FolderFileIntake.isImageFile(URL(fileURLWithPath: path))
        case .notice(let text):
            // A system notice. The phone does not know this kind and shows its text as a plain row.
            object["kind"] = "notice"
            object["text"] = text
        case .form(let record):
            object["kind"] = "form"
            object["text"] = record.message
            object["skipped"] = record.skipped
            object["lines"] = record.lines.map { ["question": $0.question, "answer": $0.answer] }
        }
        return object
    }

    private nonisolated static func json(_ reply: ChatReply) -> [String: Any] {
        var object: [String: Any] = ["item_id": reply.itemID.uuidString, "sender": reply.sender, "text": reply.text]
        if let date = reply.date { object["date"] = iso(date) }
        if reply.selection == true { object["selection"] = true }
        if let fromUser = reply.fromUser { object["from_user"] = fromUser }
        return object
    }

    /// The phone shows a short preview, so the text is cut to `selectionTextLimit` characters.
    package static let selectionTextLimit = 2_000

    private nonisolated static func json(_ selection: FrontSelection) -> [String: Any] {
        var object: [String: Any] = ["app_name": selection.appName, "text": String(selection.text.prefix(selectionTextLimit))]
        if let title = selection.windowTitle { object["window_title"] = title }
        if selection.trimmed || selection.text.count > selectionTextLimit { object["trimmed"] = true }
        return object
    }

    private nonisolated static func json(_ approval: ChatApprovalInfo) -> [String: Any] {
        var object: [String: Any] = ["id": approval.id.uuidString, "title": approval.title, "detail": approval.detail]
        if let agentId = approval.agentId { object["agent_id"] = agentId }
        if let agentName = approval.agentName { object["agent_name"] = agentName }
        return object
    }

    private nonisolated static func json(_ queued: ChatQueuedInfo) -> [String: Any] {
        var object: [String: Any] = ["id": queued.id.uuidString, "text": queued.text, "file_count": queued.files.count, "from_mac": queued.fromMac]
        if let reply = queued.reply { object["reply"] = json(reply) }
        return object
    }

    private nonisolated static func json(_ thread: ChatThreadInfo) -> [String: Any] {
        var object: [String: Any] = ["id": thread.id, "title": thread.title, "folder_label": (thread.workspace as NSString).lastPathComponent,
                                     "updated": iso(thread.updatedAt), "agent": thread.agent]
        if let name = thread.automationName { object["automation_name"] = name }
        if thread.voice == true { object["voice"] = true }
        return object
    }

    private nonisolated static func json(_ form: ChatFormInfo) -> [String: Any] {
        var answers: [String: Any] = [:]
        for (name, value) in form.answers {
            switch value {
            case .one(let text), .text(let text): answers[name] = text
            case .many(let list): answers[name] = list
            case .flag(let on): answers[name] = on
            }
        }
        var object: [String: Any] = ["id": form.id.uuidString, "message": form.form.message, "fields": form.form.fields.map(json), "answers": answers,
                                     "can_submit": form.form.canSubmit(form.answers)]
        if let agentId = form.agentId { object["agent_id"] = agentId }
        if let agentName = form.agentName { object["agent_name"] = agentName }
        return object
    }

    private nonisolated static func json(_ field: ElicitationField) -> [String: Any] {
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
package final class RemoteEventThrottle {
    private let interval: Duration
    private let deliver: (APIEvent) -> Void
    private var lastSent: [String: ContinuousClock.Instant] = [:]
    private var waiting: [String: APIEvent] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    package init(interval: Duration = .milliseconds(100), deliver: @escaping (APIEvent) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    package func push(_ event: APIEvent) {
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

    package func cancel() {
        for timer in timers.values { timer.cancel() }
        timers = [:]
        waiting = [:]
    }
}
