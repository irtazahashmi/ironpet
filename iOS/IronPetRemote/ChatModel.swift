import Foundation
import IronPetKit
import Observation
import os
import UIKit

/// Debug-level timestamps for each hop on the phone, to pair with the Mac's `mac.*` lines. A line has the hop name and a wall-clock time
/// in milliseconds, never message content.
enum PhoneHopLog {
    private static let logger = Logger(subsystem: "com.ironpet.remote", category: "send-latency")

    static func mark(_ hop: String) {
        logger.debug("hop=\(hop, privacy: .public) t=\(Int(Date().timeIntervalSince1970 * 1000), privacy: .public)")
    }
}

/// A message the user sent that the Mac has not shown back yet. The transcript draws it at once, so the send does not wait for the network.
struct OutgoingMessage: Identifiable, Equatable {
    enum State: Equatable {
        /// The upload or the send is in flight.
        case sending
        /// The Mac took it and the transcript has not shown it yet.
        case sent
        /// The send failed or the Mac did not answer in time. `retry` sends it again.
        case failed(String)
    }

    /// Draws as the transcript item `pending-<id>`.
    let id: UUID
    let text: String
    let date: Date
    var state: State
    /// The ids of the user messages the phone already had when this was sent. A new `ios` message with the same text that is not in this
    /// set is the Mac's copy of this one.
    let known: Set<String>
    var uploadIDs: [String] = []
    var reply: RemoteReplyRef?

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var itemID: String { Self.itemID(id) }
    static func itemID(_ id: UUID) -> String { "pending-\(id.uuidString)" }
    static func isPending(_ itemID: String) -> Bool { itemID.hasPrefix("pending-") }

    var item: RemoteChatItem { RemoteChatItem(id: itemID, kind: "user", date: date, origin: "ios", text: text) }
}

private struct SendTimedOut: LocalizedError {
    var errorDescription: String? { "The Mac did not answer in time." }
}

/// A photo, file or pasted image for the next message. It uploads when the message is sent.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    var fileName: String
    var contentType: String
    var data: Data
    var isImage: Bool
    /// A small picture for the composer, set for pasted images. It lives in memory only.
    var preview: UIImage?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// The Chat tab: the one chat the Mac has open. It reads `/v1/chat/current`, reads a message again when `chat.item` names it, and
/// reloads everything on connect, resync and any `chat.state`.
@MainActor @Observable
final class ChatModel: SocketModel {
    static let maxUploadBytes = 20 << 20
    /// Pending images at once, as many as the photo picker allows in one go.
    static let maxPendingImages = 4

    private(set) var snapshot: RemoteChatSnapshot?
    private(set) var items: [RemoteChatItem] = []
    var draft = ""
    var attachments: [PendingAttachment] = []
    /// The message the next one answers, with the part of it the user selected, if any.
    var replyTo: RemoteChatItem?
    private(set) var sending = false
    /// Messages sent from this phone that the transcript has not caught up with. They show at the end of `displayItems`.
    private(set) var outbox: [OutgoingMessage] = []
    /// How long the Mac has to answer a send before the message is marked failed.
    @ObservationIgnored var sendTimeout: Duration = .seconds(15)
    /// The Mac's reason for refusing to open a thread or start a chat, shown as an alert.
    var conflictMessage: String?
    /// True while a saved thread is open on top of the thread list, so only that screen presents `conflictMessage`.
    var readerOpen = false
    private(set) var threads: [RemoteChatThread] = []
    /// Photos this phone sent, by the name the Mac saved them under, so the transcript shows a thumbnail instead of a chip.
    private(set) var sentPhotos: [String: Data] = [:]
    @ObservationIgnored private var pastedCount = 0

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

    /// The Mac's transcript with this phone's unconfirmed messages after it. A message the Mac has shown back replaces its local copy, so
    /// each one appears once whichever arrives first: the answer to the send or the pushed item.
    var displayItems: [RemoteChatItem] { items + unconfirmed().map(\.item) }

    /// True while a sent message waits for the Mac, so the transcript shows the typing row before the Mac says it is running.
    var awaitingReply: Bool { unconfirmed().contains { !$0.isFailed } }

    /// The outbox without the messages the transcript already has. Each Mac item settles one local message, oldest first, so two
    /// identical texts sent in a row stay two messages until both arrive.
    private func unconfirmed() -> [OutgoingMessage] {
        var claimed = Set<String>()
        return outbox.filter { message in
            guard let match = items.first(where: { $0.kind == "user" && $0.origin == "ios" && $0.text == message.text && !message.known.contains($0.id) && !claimed.contains($0.id) }) else { return true }
            claimed.insert(match.id)
            return false
        }
    }

    private var userItemIDs: Set<String> { Set(items.filter { $0.kind == "user" }.map(\.id)) }

    private func reconcile() {
        let keep = Set(unconfirmed().map(\.id))
        guard keep.count != outbox.count else { return }
        outbox.removeAll { !keep.contains($0.id) }
        PhoneHopLog.mark("phone.confirmed")
    }

    var canSend: Bool { !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    override func reload() async { await fetch() }

    /// Reads the whole chat. Returns false when the read failed.
    @discardableResult
    private func fetch() async -> Bool {
        guard let fresh = await run({ try await self.client.chat() }) else { return false }
        snapshot = fresh
        items = fresh.items
        reconcile()
        return true
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
            PhoneHopLog.mark("phone.item")
            reconcile()
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

    /// A pasted image. It is converted to JPEG (PNG with transparency), shrunk to 2048 px and stripped of metadata off the main
    /// thread, then added with a thumbnail. Returns false when it was refused, with `errorMessage` saying why.
    @discardableResult
    func attachPastedImage(_ raw: Data) async -> Bool {
        guard attachments.filter(\.isImage).count < Self.maxPendingImages else {
            errorMessage = "You can attach up to \(Self.maxPendingImages) images to one message."
            return false
        }
        let image = await Task.detached(priority: .userInitiated) { PastedImage.normalize(data: raw) }.value
        guard let image else {
            errorMessage = "That image could not be read."
            return false
        }
        // The paste may have been the fifth while the first was still converting.
        guard attachments.filter(\.isImage).count < Self.maxPendingImages else {
            errorMessage = "You can attach up to \(Self.maxPendingImages) images to one message."
            return false
        }
        pastedCount += 1
        var pending = PendingAttachment(fileName: "pasted-image-\(pastedCount).\(image.fileExtension)", contentType: image.contentType, data: image.data, isImage: true)
        pending.preview = PastedImage.thumbnail(from: image.data)
        attachments.append(pending)
        errorMessage = nil
        return true
    }

    func removeAttachment(_ attachment: PendingAttachment) { attachments.removeAll { $0 == attachment } }

    /// Clears the composer and shows the message in the transcript at once, then uploads the attachments one by one and sends the message
    /// with their ids. When an upload fails nothing is sent, and the text, the attachments and the reply come back. When the send
    /// fails or the Mac does not answer in time, the message stays in the transcript marked failed, and `retry` sends it again.
    func send() async {
        guard canSend else { return }
        sending = true
        defer { sending = false }
        PhoneHopLog.mark("phone.send")
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = draft, pending = attachments, quoted = replyTo
        draft = ""
        attachments = []
        replyTo = nil
        func restore() {
            // Something typed while the send was running stays, after the text that came back.
            draft = draft.isEmpty ? original : original + "\n" + draft
            attachments = pending + attachments
            if replyTo == nil { replyTo = quoted }
        }
        let quote = quoted.map { RemoteReplyRef(itemID: $0.id) }
        // A message with only attachments has no text to show, so the photo or file row appears when the Mac confirms it.
        var outgoing: UUID?
        if !text.isEmpty {
            let message = OutgoingMessage(id: UUID(), text: text, date: Date(), state: .sending, known: userItemIDs, reply: quote)
            outbox.append(message)
            outgoing = message.id
        }
        var ids: [String] = []
        var photos: [String: Data] = [:]
        for attachment in pending {
            guard let upload = await run({ try await self.client.upload(attachment.data, fileName: attachment.fileName, contentType: attachment.contentType) }) else {
                outbox.removeAll { $0.id == outgoing }
                return restore()
            }
            ids.append(upload.id)
            if attachment.isImage, let stored = upload.storedName { photos[stored] = attachment.data }
        }
        if let outgoing, let index = outbox.firstIndex(where: { $0.id == outgoing }) { outbox[index].uploadIDs = ids }
        // An attachment-only message has no local copy to retry, so a failed send gives the composer its content back.
        let delivered = await deliver(outgoing, text: text, uploadIDs: ids, reply: quote, photos: photos)
        if !delivered, outgoing == nil { restore() }
    }

    /// Sends a failed message again. The state changes before the first await, so a second tap does nothing.
    func retry(_ id: UUID) async {
        guard let index = outbox.firstIndex(where: { $0.id == id }), outbox[index].isFailed else { return }
        outbox[index].state = .sending
        let message = outbox[index]
        await deliver(id, text: message.text, uploadIDs: message.uploadIDs, reply: message.reply, photos: [:])
    }

    /// Returns false when the send failed.
    @discardableResult
    private func deliver(_ id: UUID?, text: String, uploadIDs: [String], reply: RemoteReplyRef?, photos: [String: Data]) async -> Bool {
        func mark(_ state: OutgoingMessage.State) {
            if let index = outbox.firstIndex(where: { $0.id == id }) { outbox[index].state = state }
        }
        let client = self.client, timeout = sendTimeout
        PhoneHopLog.mark("phone.post")
        do {
            _ = try await Self.withTimeout(timeout) { try await client.sendMessage(text: text, uploadIDs: uploadIDs, reply: reply) }
            PhoneHopLog.mark("phone.ack")
            errorMessage = nil
        } catch ClientError.unauthorized {
            mark(.failed("Sign in again to send."))
            onUnauthorized()
            return false
        } catch is CancellationError {
            mark(.failed("The send was cancelled."))
            return false
        } catch {
            if id == nil { errorMessage = error.localizedDescription }
            mark(.failed(error.localizedDescription))
            return false
        }
        sentPhotos.merge(photos) { _, new in new }
        mark(.sent)
        // Once the whole chat is read the Mac's copy is in `items`, or the message is in its queue, so the local copy is done.
        if await fetch() { outbox.removeAll { $0.id == id } }
        return true
    }

    private static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SendTimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
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
