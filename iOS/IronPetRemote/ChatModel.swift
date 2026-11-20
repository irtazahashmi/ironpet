import Foundation
import IronPetKit
import Observation

/// A photo or file picked for the next message. It uploads when the message is sent.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    var fileName: String
    var contentType: String
    var data: Data
    var isImage: Bool
}

/// The Chat tab: the one chat the Mac has open. It reads `/v1/chat/current`, reads a message again when `chat.item` names it, and
/// reloads everything on connect, resync and any `chat.state`.
@MainActor @Observable
final class ChatModel: SocketModel {
    static let maxUploadBytes = 20 << 20

    private(set) var snapshot: RemoteChatSnapshot?
    private(set) var items: [RemoteChatItem] = []
    var draft = ""
    var attachments: [PendingAttachment] = []
    /// The message the next one answers, with the part of it the user selected, if any.
    var replyTo: RemoteChatItem?
    private(set) var sending = false
    /// The Mac's reason for refusing to open a thread or start a chat, shown as an alert.
    var conflictMessage: String?
    private(set) var threads: [RemoteChatThread] = []
    /// Photos this phone sent, by the name the Mac saved them under, so the transcript shows a thumbnail instead of a chip.
    private(set) var sentPhotos: [String: Data] = [:]

    var approvals: [RemoteApproval] { snapshot?.approvals ?? [] }
    var forms: [RemoteForm] { snapshot?.forms ?? [] }
    var queue: [RemoteQueued] { snapshot?.queue ?? [] }
    var running: Bool { snapshot?.running ?? false }
    var title: String { snapshot?.title ?? "Chat" }

    /// "Claude Code · demo-app · Working", for the header.
    var subtitle: String {
        guard let snapshot else { return "" }
        let state: String
        switch snapshot.state {
        case "running": state = snapshot.activity ?? "Working"
        case "failed": state = "Failed"
        case "done": state = "Done"
        default: state = "Idle"
        }
        return [snapshot.agent.name, snapshot.folderLabel, state].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var canSend: Bool { !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    override func reload() async {
        guard let fresh = await run({ try await self.client.chat() }) else { return }
        snapshot = fresh
        items = fresh.items
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.chatItem:
            guard let id = event.id else { return await reload() }
            await refreshItem(id)
        case RemoteEvent.chatState:
            await reload()
        default: break
        }
    }

    /// One streamed message: read it and replace it, or add it at the end. A message the Mac no longer has means the chat changed under us.
    private func refreshItem(_ id: String) async {
        do {
            let item = try await client.chatMessage(id: id)
            if let index = items.firstIndex(where: { $0.id == id }) { items[index] = item } else { items.append(item) }
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch ClientError.api(404, _, _) {
            await reload()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Composer

    func attach(data: Data, fileName: String, contentType: String) {
        guard data.count <= Self.maxUploadBytes else {
            errorMessage = "\(fileName) is larger than 20 MB, which the Mac does not accept."
            return
        }
        attachments.append(PendingAttachment(fileName: fileName, contentType: contentType, data: data, isImage: contentType.hasPrefix("image/")))
    }

    func removeAttachment(_ attachment: PendingAttachment) { attachments.removeAll { $0 == attachment } }

    /// Uploads the attachments one by one, then sends the message with their ids. When an upload fails nothing is sent and the draft stays.
    func send() async {
        guard canSend else { return }
        sending = true
        defer { sending = false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var ids: [String] = []
        var photos: [String: Data] = [:]
        for attachment in attachments {
            guard let upload = await run({ try await self.client.upload(attachment.data, fileName: attachment.fileName, contentType: attachment.contentType) }) else { return }
            ids.append(upload.id)
            if attachment.isImage, let stored = upload.storedName { photos[stored] = attachment.data }
        }
        let quote = replyTo.map { RemoteReplyRef(itemID: $0.id) }
        guard await run({ try await self.client.sendMessage(text: text, uploadIDs: ids, reply: quote) }) != nil else { return }
        sentPhotos.merge(photos) { _, new in new }
        draft = ""
        attachments = []
        replyTo = nil
        await reload()
    }

    func stopTurn() async {
        if await run({ try await self.client.stopChat() }) != nil { await reload() }
    }

    // MARK: Approvals and forms

    func decide(_ approval: RemoteApproval, allow: Bool) async {
        if await run({ try await self.client.decide(approval: approval.id, allow: allow) }) != nil { await reload() }
    }

    func answer(_ form: RemoteForm, field: String, _ value: RemoteFormAnswer) async {
        if await run({ try await self.client.answer(form: form.id, answers: [field: value]) }) != nil { await reload() }
    }

    func submit(_ form: RemoteForm) async {
        if await run({ try await self.client.submit(form: form.id) }) != nil { await reload() }
    }

    func skip(_ form: RemoteForm) async {
        if await run({ try await self.client.skip(form: form.id) }) != nil { await reload() }
    }

    // MARK: Threads

    func loadThreads() async {
        if let list = await run({ try await self.client.chatThreads() }) { threads = list }
    }

    func thread(_ id: String) async -> RemoteChatThreadDetail? { await run { try await self.client.chatThread(id: id) } }

    /// Makes a saved thread the Mac's chat. Returns true when the Mac did it; a 409 sets `conflictMessage` and returns false.
    @discardableResult
    func open(_ thread: RemoteChatThread) async -> Bool { await change { try await self.client.openThread(id: thread.id) } }

    @discardableResult
    func newChat() async -> Bool { await change { try await self.client.newChat() } }

    private func change(_ call: () async throws -> Void) async -> Bool {
        do {
            try await call()
            errorMessage = nil
            await reload()
            return true
        } catch ClientError.api(409, _, let message) {
            conflictMessage = message
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }
}
