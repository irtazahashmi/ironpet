import Foundation
import IronPetKit
import Observation
import os
import UIKit

/// Debug-level timestamps for each hop on the phone, to pair with the Mac's `mac.*` lines. A line has the hop name and a wall-clock time
/// in milliseconds, never message content.
enum PhoneHopLog {
    private static let logger = Logger(subsystem: "com.ironpet.remote", category: "send-latency")

    /// Called with each hop name. Tests read it; nothing sets it in the app.
    nonisolated(unsafe) static var tap: ((String) -> Void)?

    static func mark(_ hop: String) {
        tap?(hop)
        logger.debug("hop=\(hop, privacy: .public) t=\(Int(Date().timeIntervalSince1970 * 1000), privacy: .public)")
    }
}

/// A message the user sent that the Mac has not shown back yet. The transcript draws it at once, so the send does not wait for the network.
struct OutgoingMessage: Identifiable, Equatable {
    enum State: Equatable {
        /// The phone cannot reach the Mac. The message is saved on the phone and goes out, in order, when the connection is back.
        case waiting
        /// The upload or the send is in flight.
        case sending
        /// The Mac took it and the transcript has not shown it yet.
        case sent
        /// The send failed or the Mac did not answer in time. `retry` sends it again.
        case failed(String)
    }

    /// Draws as the transcript item `pending-<id>`.
    let id: UUID
    var text: String
    let date: Date
    var state: State
    /// The ids of the user messages the phone already had when this was sent. A new `ios` message with the same text that is not in this
    /// set is the Mac's copy of this one.
    var known: Set<String>
    var uploadIDs: [String] = []
    var reply: RemoteReplyRef?
    /// A message dictated and sent at once. Its text is empty until the Mac sends the transcript back.
    var isVoice = false
    /// When the message first started waiting for the connection. The age limit counts from here. Retry clears it.
    var queuedAt: Date?
    /// Loaded from the saved outbox after a launch. The transcript cannot hold its copy, since the phone does not know whether an
    /// earlier launch sent it, so it never settles against an item until it is sent again.
    var restored = false

    var isWaiting: Bool { state == .waiting }

    /// A voice message whose text the Mac has not sent yet.
    var isTranscribing: Bool { isVoice && text.isEmpty }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var itemID: String { Self.itemID(id) }
    static func itemID(_ id: UUID) -> String { "pending-\(id.uuidString)" }
    static func isPending(_ itemID: String) -> Bool { itemID.hasPrefix("pending-") }

    var item: RemoteChatItem { RemoteChatItem(id: itemID, kind: "user", date: date, origin: "ios", text: isTranscribing ? (isFailed ? "Voice message" : "Transcribing…") : text) }
}

/// Plain wording for a failed request. URLSession's own text ("The request timed out.", "The network connection was lost.") never reaches the chat.
enum PlainError {
    static let unreachable = "Can't reach your Mac."

    static func message(for error: Error) -> String {
        if let client = error as? ClientError {
            switch client {
            case .transport: return unreachable
            default: return client.errorDescription ?? unreachable
            }
        }
        if error is URLError { return unreachable }
        if let known = error as? SendTimedOut { return known.errorDescription ?? unreachable }
        return "Something went wrong. Try again."
    }
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
    /// The event socket, set by the app. Typed messages go over it while it is open. Nil in tests that use HTTPS only.
    @ObservationIgnored var socket: (any ChatSocket)?
    /// A message that waits longer than this for the connection is not sent on its own any more. It shows Retry instead.
    static let maxWaitingAge: TimeInterval = 24 * 60 * 60
    /// The most messages the phone keeps waiting. The Mac remembers the last 512 client ids per device, so this stays well inside
    /// the window in which a resend is still recognized.
    static let outboxCapacity = 100
    /// Where waiting messages are saved. Set with `useOutbox`.
    @ObservationIgnored private var outboxStore: (any OutboxStoring)?
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var flushing = false
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
    @ObservationIgnored private var pickedCount = 0
    /// Why the last upload failed, while the composer holds the attachments again. The composer shows it with a Retry.
    private(set) var uploadFailure: String?
    /// Screenshots and attached images the Mac holds, fetched by the id of their message.
    @ObservationIgnored lazy var images = ChatImages(client: client)
    /// True after a run of failed background reads (3 tries, or 10 s since the first). Shows one banner with Retry, and clears when a read works.
    private(set) var connectionLost = false
    @ObservationIgnored var bannerAfterTries = 3
    @ObservationIgnored var bannerAfter: Duration = .seconds(10)
    /// The wait before the first quiet retry. Each failure doubles it, up to 8 times this.
    @ObservationIgnored var retryBase: Duration = .seconds(1)
    @ObservationIgnored private var readFailures = 0
    @ObservationIgnored private var firstReadFailure: ContinuousClock.Instant?
    /// The one pending quiet retry. A failure while it waits does not start another.
    @ObservationIgnored private var quietRetry: Task<Void, Never>?

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
    var awaitingReply: Bool { unconfirmed().contains { !$0.isFailed && !$0.isWaiting } }

    /// The outbox without the messages the transcript already has. Each Mac item settles one local message, oldest first, so two
    /// identical texts sent in a row stay two messages until both arrive.
    /// A voice message with no text yet takes any new `ios` item, but only after the messages with text took theirs.
    private func unconfirmed() -> [OutgoingMessage] {
        var claimed = Set<String>()
        var settled = Set<UUID>()
        for transcribing in [false, true] {
            // A waiting message never reached the Mac, so no item in the transcript can be its copy.
            for message in outbox where message.isTranscribing == transcribing && !message.isWaiting && !message.restored {
                guard let match = items.first(where: { $0.kind == "user" && $0.origin == "ios" && (transcribing || $0.text == message.text) && !message.known.contains($0.id) && !claimed.contains($0.id) }) else { continue }
                claimed.insert(match.id)
                settled.insert(message.id)
            }
        }
        return outbox.filter { !settled.contains($0.id) }
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

    override func stop() {
        quietRetry?.cancel()
        quietRetry = nil
        super.stop()
    }

    override func message(for error: Error) -> String { PlainError.message(for: error) }

    /// Reads the whole chat. Returns false when the read failed. A failure retries quietly, and only a run of them shows the banner.
    @discardableResult
    private func fetch() async -> Bool {
        do {
            let fresh = try await client.chat()
            snapshot = fresh
            items = fresh.items
            fullReads += 1
            errorMessage = nil
            readSucceeded()
            quietRetry?.cancel()
            quietRetry = nil
            reconcile()
            return true
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { readFailed() }
        }
        return false
    }

    /// The Retry button: reads now instead of waiting for the next quiet retry.
    func retryNow() async {
        quietRetry?.cancel()
        quietRetry = nil
        await fetch()
    }

    private func readSucceeded() {
        readFailures = 0
        firstReadFailure = nil
        connectionLost = false
    }

    private func readFailed() {
        readFailures += 1
        let first = firstReadFailure ?? .now
        firstReadFailure = first
        if readFailures >= bannerAfterTries || ContinuousClock.now - first >= bannerAfter { connectionLost = true }
        guard quietRetry == nil else { return }
        let delay = retryBase * (1 << min(readFailures - 1, 3))
        quietRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.quietRetry = nil
            await self.fetch()
        }
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.chatItem:
            guard let id = event.id else { return await reload() }
            if let item = event.item, item.id == id {
                // The Mac sent the message with the event: no read needed.
                PhoneHopLog.mark("phone.event")
                apply(item, from: .event)
            } else {
                // An older Mac, or a message too long to send along. The read runs on its own task so the next event is not held
                // up behind it.
                requestRefresh(id)
            }
        case RemoteEvent.chatState:
            await reload()
        default: break
        }
    }

    private enum Source { case event, read }

    /// Bumped each time a message changes from an event or a full read. A read that started before the bump holds older text.
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var fullReads = 0
    /// The messages with a read in flight, and those that changed again while it ran.
    @ObservationIgnored private var refreshing: Set<String> = []
    @ObservationIgnored private var stale: Set<String> = []

    private func apply(_ item: RemoteChatItem, from source: Source) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            if items[index] != item { items[index] = item }
        } else {
            items.append(item)
        }
        if source == .event { revisions[item.id, default: 0] += 1 }
        reconcile()
    }

    /// Reads one message again. At most one read per message runs at a time. An event that arrives meanwhile marks the message stale,
    /// and the read runs once more when the first ends, so the last state wins and a burst costs two reads, not one per event.
    private func requestRefresh(_ id: String) {
        guard refreshing.insert(id).inserted else {
            stale.insert(id)
            return
        }
        Task { [weak self] in
            while let self {
                self.stale.remove(id)
                await self.refreshItem(id)
                guard self.stale.contains(id) else { break }
            }
            self?.refreshing.remove(id)
        }
    }

    /// One streamed message: read it and replace it, or add it at the end. A message the Mac no longer has means the chat changed under us.
    private func refreshItem(_ id: String) async {
        let revision = revisions[id, default: 0], reads = fullReads
        do {
            let item = try await client.chatMessage(id: id)
            // An event or a full read that finished while this one was in flight holds newer text than this answer.
            guard revisions[id, default: 0] == revision, fullReads == reads else { return }
            apply(item, from: .read)
            PhoneHopLog.mark("phone.item")
            readSucceeded()
        } catch ClientError.unauthorized {
            onUnauthorized()
        } catch ClientError.api(404, _, _) {
            await reload()
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { readFailed() }
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
        pastedCount += 1
        return await attachImage(raw, name: "pasted-image-\(pastedCount)")
    }

    /// Photos from the picker. Each loader returns the photo's bytes. A photo that cannot be loaded is reported, and the others still
    /// attach. The picker hands over HEIC and full-size originals, so they go through the same conversion as a pasted image.
    func attachPhotos(_ loaders: [@Sendable () async throws -> Data?]) async {
        var failed = 0
        for load in loaders {
            guard let raw = try? await load(), !raw.isEmpty else { failed += 1; continue }
            pickedCount += 1
            // The limit or an unreadable image sets its own message, which matters more than the load count.
            if await !attachImage(raw, name: "photo-\(pickedCount)") { return }
        }
        if failed > 0 {
            errorMessage = failed == 1 ? "A photo could not be loaded. Try picking it again." : "\(failed) photos could not be loaded. Try picking them again."
        }
    }

    private func attachImage(_ raw: Data, name: String) async -> Bool {
        guard attachments.filter(\.isImage).count < Self.maxPendingImages else {
            errorMessage = "You can attach up to \(Self.maxPendingImages) images to one message."
            return false
        }
        let image = await Task.detached(priority: .userInitiated) { PastedImage.normalize(data: raw) }.value
        guard let image else {
            errorMessage = "That image could not be read."
            return false
        }
        // The next one may have been added while this one was still converting.
        guard attachments.filter(\.isImage).count < Self.maxPendingImages else {
            errorMessage = "You can attach up to \(Self.maxPendingImages) images to one message."
            return false
        }
        var pending = PendingAttachment(fileName: "\(name).\(image.fileExtension)", contentType: image.contentType, data: image.data, isImage: true)
        pending.preview = PastedImage.thumbnail(from: image.data)
        attachments.append(pending)
        errorMessage = nil
        return true
    }

    func removeAttachment(_ attachment: PendingAttachment) {
        attachments.removeAll { $0 == attachment }
        if attachments.isEmpty { uploadFailure = nil }
    }

    /// Clears the composer and shows the message in the transcript at once, then uploads the attachments one by one and sends the message
    /// with their ids. When an upload fails nothing is sent, and the text, the attachments and the reply come back. When the send
    /// fails or the Mac does not answer in time, the message stays in the transcript marked failed, and `retry` sends it again.
    func send() async {
        guard canSend else { return }
        uploadFailure = nil
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
                // `run` already put the reason in `errorMessage`. A sign-out leaves none, and then there is nothing to retry.
                uploadFailure = errorMessage.map { "The upload failed. \($0)" }
                return restore()
            }
            ids.append(upload.id)
            if attachment.isImage, let stored = upload.storedName { photos[stored] = attachment.data }
        }
        if let outgoing, let index = outbox.firstIndex(where: { $0.id == outgoing }) { outbox[index].uploadIDs = ids }
        // An attachment-only message has no local copy to retry, so a failed send gives the composer its content back.
        let delivered = await deliver(outgoing, text: text, uploadIDs: ids, reply: quote, photos: photos)
        if delivered != .delivered, outgoing == nil { restore() }
    }

    /// Sends `text` as its own message and leaves the composer, its attachments and its reply as they are. The Tasks tab uses it for
    /// the quick filter prompts. A failure shows on the message in the chat, with Retry.
    func sendPrompt(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = OutgoingMessage(id: UUID(), text: text, date: Date(), state: .sending, known: userItemIDs, reply: nil)
        outbox.append(message)
        await deliver(message.id, text: text, uploadIDs: [], reply: nil, photos: [:])
    }

    /// Sends a failed message again. The state changes before the first await, so a second tap does nothing.
    func retry(_ id: UUID) async {
        guard let index = outbox.firstIndex(where: { $0.id == id }), outbox[index].isFailed else { return }
        outbox[index].state = .sending
        // A retry starts the waiting clock again, so a message the user retries is not failed for its old age at the next reconnect.
        outbox[index].queuedAt = nil
        outbox[index].restored = false
        let message = outbox[index]
        // A voice message without text sends its audio again. One with text only needs the Mac to put it in the chat.
        if message.isTranscribing { return await resendVoice(id.uuidString.lowercased()) }
        await deliver(id, text: message.text, uploadIDs: message.uploadIDs, reply: message.reply, photos: [:])
    }

    private enum Delivery {
        case delivered
        /// The Mac answered that it will not take the message.
        case refused
        /// The phone could not reach the Mac, and the message now waits in the outbox.
        case offline
        /// Anything else: the Mac did not answer in time, the token is gone, or the outbox is full.
        case failed
    }

    @discardableResult
    private func deliver(_ id: UUID?, text: String, uploadIDs: [String], reply: RemoteReplyRef?, photos: [String: Data]) async -> Delivery {
        func mark(_ state: OutgoingMessage.State) {
            if let index = outbox.firstIndex(where: { $0.id == id }) { outbox[index].state = state }
            persistOutbox()
        }
        // Only a plain text message can wait. Attachments upload first, and a voice message has its own path.
        let canQueue = id != nil && uploadIDs.isEmpty && !text.isEmpty
        // A message typed while an earlier one waits or is on its way from the outbox goes behind it, so the Mac sees them in order.
        if canQueue, let id, let index = outbox.firstIndex(where: { $0.id == id }), outbox[..<index].contains(where: { $0.queuedAt != nil && ($0.isWaiting || $0.state == .sending) }) {
            enqueue(id)
            kickFlush()
            return .offline
        }
        let client = self.client, timeout = sendTimeout
        // The id is the message's own, so a Retry sends the same id and the Mac creates the message once.
        let clientID = (id ?? UUID()).uuidString.lowercased()
        do {
            try await Self.withTimeout(timeout) { [socket] in
                // The open event socket carries messages without attachments. Without it, or when the Mac did not announce `chat.send`,
                // the send goes over HTTPS as before.
                if uploadIDs.isEmpty, let socket, socket.canSendChat {
                    PhoneHopLog.mark("phone.socket")
                    do {
                        _ = try await socket.sendChat(clientID: clientID, text: text, reply: reply)
                        PhoneHopLog.mark("phone.socket.ack")
                        return
                    } catch SocketSendError.unavailable {
                    } catch SocketSendError.closed {
                        // The socket closed after the frame left. The Mac may have taken it, and the same id makes the HTTPS send safe.
                    }
                }
                PhoneHopLog.mark("phone.post")
                _ = try await client.sendMessage(text: text, uploadIDs: uploadIDs, reply: reply, clientID: clientID)
                PhoneHopLog.mark("phone.ack")
            }
            errorMessage = nil
        } catch SocketSendError.refused(_, let message) {
            mark(.failed(message))
            return .refused
        } catch ClientError.unauthorized {
            mark(.failed("Sign in again to send."))
            onUnauthorized()
            return .failed
        } catch is CancellationError {
            mark(.failed("The send was cancelled."))
            return .failed
        } catch where canQueue && Self.isUnreachable(error) {
            // The Mac is out of reach (no network, asleep, relay down). Keep the message and send it on the next connect.
            if let id { enqueue(id) }
            return outbox.contains { $0.id == id && $0.isWaiting } ? .offline : .failed
        } catch {
            // The failed row under the message carries the reason and its Retry. No banner repeats it.
            mark(.failed(PlainError.message(for: error)))
            return .failed
        }
        sentPhotos.merge(photos) { _, new in new }
        mark(.sent)
        // Once the whole chat is read the Mac's copy is in `items`, or the message is in its queue, so the local copy is done.
        if await fetch() { outbox.removeAll { $0.id == id } }
        persistOutbox()
        return .delivered
    }

    /// True when the Mac could not be reached. The relay answers 502, 503 or 504 when it cannot reach the Mac (tunnel down, Mac asleep).
    /// Any other status came from the Mac itself, so the message fails with Retry.
    private static func isUnreachable(_ error: Error) -> Bool {
        switch error {
        case ClientError.transport: return true
        case ClientError.api(let status, _, _): return [502, 503, 504].contains(status)
        default: return error is URLError
        }
    }

    // MARK: Outbox

    /// Loads the saved outbox and keeps saving it from now on. Call it once, before `start()`. A message that was waiting or on its
    /// way when the app ended comes back as waiting: a resend carries the same client id, so the Mac still makes it once.
    func useOutbox(_ store: any OutboxStoring) {
        outboxStore = store
        let restored = store.load().filter { record in !outbox.contains { $0.id == record.id } }
        for record in restored.prefix(Self.outboxCapacity) {
            var message = OutgoingMessage(id: record.id, text: record.text, date: record.date, state: record.failure.map { .failed($0) } ?? .waiting, known: [], reply: record.reply)
            message.queuedAt = record.queuedAt
            message.restored = true
            outbox.append(message)
        }
        outbox.sort { $0.date < $1.date }
    }

    private func persistOutbox() {
        guard let outboxStore else { return }
        let records: [OutboxRecord] = outbox.compactMap { message in
            guard let queuedAt = message.queuedAt else { return nil }
            var failure: String?
            switch message.state {
            case .waiting, .sending: break
            case .failed(let reason): failure = reason
            case .sent: return nil
            }
            return OutboxRecord(id: message.id, text: message.text, date: message.date, queuedAt: queuedAt, replyItemID: message.reply?.itemID, replySelection: message.reply?.selectionText, failure: failure)
        }
        outboxStore.save(records)
    }

    /// Marks a message as waiting for the connection. A full outbox fails the new message instead, which then shows Retry.
    private func enqueue(_ id: UUID) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        if outbox[index].queuedAt == nil {
            guard outbox.filter({ $0.queuedAt != nil }).count < Self.outboxCapacity else {
                outbox[index].state = .failed("Too many messages are waiting to send. Delete some, or wait for your Mac.")
                return
            }
            outbox[index].queuedAt = now()
        }
        outbox[index].state = .waiting
        persistOutbox()
    }

    /// Removes a message that waits or failed before the Mac got it. A message already on its way cannot be taken back.
    func deleteQueued(_ id: UUID) {
        guard let index = outbox.firstIndex(where: { $0.id == id }), outbox[index].isWaiting || outbox[index].isFailed else { return }
        outbox.remove(at: index)
        persistOutbox()
    }

    private func kickFlush() {
        guard !flushing else { return }
        Task { [weak self] in await self?.flushOutbox() }
    }

    override func handle(_ signal: EventSignal) async {
        await super.handle(signal)
        switch signal {
        case .connected, .resync: kickFlush()
        default: break
        }
    }

    /// Sends the waiting messages one at a time, oldest first, each after the Mac answered the one before. It stops at the first
    /// message that cannot reach the Mac, so the order holds. A message the Mac refuses, or one older than `maxWaitingAge`, shows
    /// Retry and is skipped.
    func flushOutbox() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while let index = outbox.firstIndex(where: \.isWaiting) {
            let message = outbox[index]
            if let queuedAt = message.queuedAt, now().timeIntervalSince(queuedAt) > Self.maxWaitingAge {
                outbox[index].state = .failed("Waited more than 24 hours, so it was not sent.")
                persistOutbox()
                continue
            }
            outbox[index].state = .sending
            outbox[index].restored = false
            // Messages the Mac showed while this one waited are not its copy.
            outbox[index].known = userItemIDs
            persistOutbox()
            switch await deliver(message.id, text: message.text, uploadIDs: [], reply: message.reply, photos: [:]) {
            case .delivered, .refused: continue
            case .offline, .failed: return
            }
        }
    }

    // MARK: Voice

    /// Sends the audio of a failed voice message again. Set by the app to `VoiceModel.resend`.
    @ObservationIgnored var resendVoice: (String) async -> Void = { _ in }

    /// Applies what happened to a voice message sent at once. The stream id is the message id, so the pending item is the one Stop made.
    func voiceEvent(_ event: VoiceModel.SendEvent) {
        func index(_ id: String) -> Int? { UUID(uuidString: id).flatMap { uuid in outbox.firstIndex { $0.id == uuid } } }
        switch event {
        case .started(let id):
            guard let uuid = UUID(uuidString: id), index(id) == nil else { return }
            var message = OutgoingMessage(id: uuid, text: "", date: Date(), state: .sending, known: userItemIDs)
            message.isVoice = true
            outbox.append(message)
        case .transcribed(let id, let text):
            guard let at = index(id) else { return }
            outbox[at].text = text
            outbox[at].state = .sent
            reconcile()
        case .failed(let id, let reason):
            guard let at = index(id) else { return }
            outbox[at].state = .failed(reason)
        case .discarded(let id):
            outbox.removeAll { $0.id == UUID(uuidString: id) }
        }
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

    /// Applies one change to the Mac chat's settings. A 409 (a turn is running) sets `conflictMessage`. The snapshot reloads either way, so
    /// a rejected choice snaps back to what the Mac has.
    @discardableResult
    func setOptions(_ change: RemoteChatOptionsChange) async -> Bool {
        let done = await self.change { try await self.client.setChatOptions(change) }
        if !done { await reload() }
        return done
    }

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
            errorMessage = PlainError.message(for: error)
        }
        return false
    }
}
