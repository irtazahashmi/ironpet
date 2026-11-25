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
    /// Photos and files that upload when the message is sent. They stay on the message until it is delivered, so a waiting message can
    /// be sent after a relaunch.
    var files: [StagedFile] = []
    /// The recording of a voice message that could not be sent live, as 16 kHz mono 16-bit PCM. Dropped once the text is known.
    var audio: Data?
    /// A voice message the phone turns into text first and then sends itself, with the client id. Set when it carries attachments or
    /// was recorded offline. The Mac never claims its text, so no pushed item can settle it by mistake.
    var local = false
    /// When the message first started waiting for the connection. The age limit counts from here. Retry clears it.
    var queuedAt: Date?
    /// Loaded from the saved outbox after a launch. The transcript cannot hold its copy, since the phone does not know whether an
    /// earlier launch sent it, so it never settles against an item until it is sent again.
    var restored = false

    var isWaiting: Bool { state == .waiting }

    /// A voice message whose text the Mac has not sent yet.
    var isTranscribing: Bool { isVoice && text.isEmpty }

    /// A message of photos or files with no text. The Mac's copy has no text to match, so a full read settles it.
    var isAttachmentOnly: Bool { !isVoice && text.isEmpty && !files.isEmpty }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var itemID: String { Self.itemID(id) }
    static func itemID(_ id: UUID) -> String { "pending-\(id.uuidString)" }
    static func isPending(_ itemID: String) -> Bool { itemID.hasPrefix("pending-") }

    var item: RemoteChatItem { RemoteChatItem(id: itemID, kind: "user", date: date, origin: "ios", text: isTranscribing ? (isFailed ? "Voice message" : "Transcribing…") : (isAttachmentOnly ? (files.allSatisfy(\.isImage) ? "Photo" : "Attachment") : text)) }
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

/// A photo or file of a message that has left the composer. Its bytes stay on the phone until the Mac has the message.
struct StagedFile: Equatable {
    var fileName: String
    var contentType: String
    var data: Data
    var isImage: Bool
}

/// What the Mac made of a saved recording.
enum SavedTranscript: Equatable {
    case text(String)
    /// The Mac heard no speech.
    case empty
    /// The phone could not reach the Mac. The recording keeps waiting.
    case unreachable
    case failed(String)
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
    /// The newest messages a read asks for, and the page before the oldest one shown.
    static let pageSize = 50
    /// Whether messages exist before `items`. Older pages load when the top of the transcript shows.
    private(set) var hasOlderHistory = false
    @ObservationIgnored private(set) var loadingOlder = false
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    /// The ETag of the page the Mac last answered and the phone holds as it is. Nil once a message changed on the phone, so the next read asks in full.
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var cache: (any ChatCaching)?
    @ObservationIgnored private var reloadDebounce: Task<Void, Never>?
    var draft = ""
    var attachments: [PendingAttachment] = []
    /// The message the next one answers.
    var replyTo: RemoteChatItem? {
        didSet { if replyTo == nil || replyTo?.id != oldValue?.id { replySelection = nil } }
    }
    /// The part of `replyTo` the reader selected and chose Ask about this for. Nil when the whole message is quoted.
    var replySelection: String?
    private(set) var sending = false

    /// Starts a reply to `item`, quoting only `selection` when the reader selected part of it. Blank text counts as no selection.
    func reply(to item: RemoteChatItem, selection: String? = nil) {
        let trimmed = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        replyTo = item
        replySelection = trimmed?.isEmpty == false ? trimmed : nil
    }
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
    /// The names of the files already written to the outbox store, so a save does not write them again.
    @ObservationIgnored private var savedFiles: Set<String> = []
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
    /// The last message typed on this phone that the Mac has confirmed, which shows the check. Earlier ones stay quiet.
    var deliveredID: String? {
        guard let last = items.last(where: { $0.kind == "user" && $0.origin == "ios" }) else { return nil }
        return outbox.contains { $0.itemID == last.id } ? nil : last.id
    }

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
            for message in outbox where message.isTranscribing == transcribing && !message.isWaiting && !message.restored && !message.isAttachmentOnly && !(transcribing && message.local) {
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
        reloadDebounce?.cancel()
        reloadDebounce = nil
        super.stop()
    }

    /// Loads the page of messages before the oldest one shown. The transcript calls it when its top comes into view, so a long chat
    /// reads a page at a time. A failure leaves the top as it was; the next time the top shows, it tries again.
    func loadOlder() async {
        guard hasOlderHistory, !loadingOlder, let oldest = items.first?.id else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let page = await read({ try await self.client.chat(limit: Self.pageSize, before: oldest) }) else { return }
        let shown = Set(items.map(\.id))
        items = page.items.filter { !shown.contains($0.id) } + items
        hasOlderHistory = page.hasMore ?? false
    }

    /// A reload after a burst of `chat.state` events. It waits until the events stop, so a turn that changes the state many times reads
    /// the chat once.
    private func scheduleReload() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.reload()
        }
    }

    /// Reads the newest page of chat, and keeps the older pages already loaded before it. Returns false when the read failed. The shared
    /// client retries and reports, so a failure here only leaves the transcript as it was.
    @discardableResult
    private func fetch() async -> Bool {
        guard let result = await read({ try await self.client.chatIfChanged(etag: self.etag, limit: Self.pageSize) }) else { return false }
        // A 304 means the Mac's chat is still the page saved with this ETag: what is shown already is current.
        switch result {
        case .notModified: break
        case .snapshot(let fresh, let newETag): adopt(fresh, etag: newETag)
        }
        lastRead = ContinuousClock.now
        errorMessage = nil
        // A sent message of attachments only has no text to match. The full read holds the Mac's copy.
        outbox.removeAll { $0.isAttachmentOnly && $0.state == .sent }
        reconcile()
        return true
    }

    /// Takes the newest page the Mac answered. It replaces the newest messages, keeps the older pages already loaded, and is saved with
    /// its ETag for the next launch.
    private func adopt(_ fresh: RemoteChatSnapshot, etag newETag: String?) {
        snapshot = fresh
        // The messages before the page's first one stay, since they were loaded on scroll. Only a read with none loaded takes `hasMore`.
        let older = fresh.items.first.flatMap { first in items.firstIndex { $0.id == first.id } } ?? 0
        items = Array(items.prefix(older)) + fresh.items
        if older == 0 { hasOlderHistory = fresh.hasMore ?? false }
        fullReads += 1
        etag = newETag
        cache?.save(SavedChat(etag: newETag, snapshot: Self.savable(fresh), hasOlderHistory: fresh.hasMore ?? false))
    }

    /// The part of a page worth keeping on disk: the messages and the chat's name and agent. Approvals, forms, the queue and a running
    /// turn are the live Mac's, so a saved page never offers them.
    static func savable(_ page: RemoteChatSnapshot) -> RemoteChatSnapshot {
        var saved = page
        saved.approvals = []
        saved.forms = []
        saved.queue = []
        saved.running = false
        saved.activity = nil
        saved.runStarted = nil
        return saved
    }

    /// Shows the chat saved last time, at once, and saves each page the Mac answers from now on. Only a launch with nothing shown loads it.
    func useCache(_ cache: any ChatCaching) {
        self.cache = cache
        guard let saved = cache.load(), snapshot == nil, items.isEmpty else { return }
        snapshot = saved.snapshot
        items = saved.snapshot.items
        hasOlderHistory = saved.hasOlderHistory
        etag = saved.etag
    }

    override func handle(_ event: RemoteEvent) async {
        switch event.kind {
        case RemoteEvent.chatItem:
            guard let id = event.id else { return await reload() }
            // With older pages loaded, a message the phone does not hold may sit above the end. The newest page places it.
            if hasOlderHistory, !items.contains(where: { $0.id == id }) { return scheduleReload() }
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
            scheduleReload()
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
        // The shown messages no longer match the saved page, so the saved ETag cannot vouch for them. The saved file stays as it was.
        etag = nil
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
        guard let item = await read({ try await self.client.chatMessage(id: id) }) else {
            // A message the Mac no longer has means the chat changed under us.
            if case ClientError.api(404, _, _)? = lastError { await reload() }
            return
        }
        // An event or a full read that finished while this one was in flight holds newer text than this answer.
        guard revisions[id, default: 0] == revision, fullReads == reads else { return }
        apply(item, from: .read)
        PhoneHopLog.mark("phone.item")
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
        let original = draft, pending = attachments, quoted = replyTo, quotedSelection = replySelection
        draft = ""
        attachments = []
        replyTo = nil
        replySelection = nil
        func restore() {
            // Something typed while the send was running stays, after the text that came back.
            draft = draft.isEmpty ? original : original + "\n" + draft
            attachments = pending + attachments
            if replyTo == nil { replyTo = quoted; replySelection = quotedSelection }
        }
        let quote = quoted.map { RemoteReplyRef(itemID: $0.id, selectionText: quotedSelection) }
        // Every message goes through the outbox, with its attachments, so one that cannot be sent now waits with its photos.
        var message = OutgoingMessage(id: UUID(), text: text, date: Date(), state: .sending, known: userItemIDs, reply: quote)
        message.files = pending.map { StagedFile(fileName: $0.fileName, contentType: $0.contentType, data: $0.data, isImage: $0.isImage) }
        outbox.append(message)
        // A message the Mac or the connection refuses stays in the transcript with Retry, and its attachments stay with it.
        let result = await deliver(message.id, restoreOnUploadFailure: true)
        if case .uploadFailed(let reason) = result {
            outbox.removeAll { $0.id == message.id }
            // A sign-out leaves no reason, and then there is nothing to retry.
            errorMessage = reason.isEmpty ? nil : reason
            uploadFailure = reason.isEmpty ? nil : "The upload failed. \(reason)"
            return restore()
        }
        // A message of attachments only has no text to show or retry, so a send the Mac refused gives the composer its content back.
        if text.isEmpty, result == .failed || result == .refused {
            outbox.removeAll { $0.id == message.id }
            persistOutbox()
            restore()
        }
    }

    /// Sends `text` as its own message and leaves the composer, its attachments and its reply as they are. The Tasks tab uses it for
    /// the quick filter prompts. A failure shows on the message in the chat, with Retry.
    func sendPrompt(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = OutgoingMessage(id: UUID(), text: text, date: Date(), state: .sending, known: userItemIDs, reply: nil)
        outbox.append(message)
        await deliver(message.id)
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
        if message.isTranscribing {
            if message.audio != nil { await sendSavedVoice(id) } else { await resendVoice(id.uuidString.lowercased()) }
            return
        }
        await deliver(id)
    }

    private enum Delivery: Equatable {
        case delivered
        /// The Mac answered that it will not take the message.
        case refused
        /// The phone could not reach the Mac, and the message now waits in the outbox.
        case offline
        /// An attachment could not be uploaded for a reason other than a missing connection. Only returned when the caller asked for it.
        case uploadFailed(String)
        /// Anything else: the Mac did not answer in time, the token is gone, or the outbox is full.
        case failed
    }

    /// Sends the message of the outbox with this id: uploads its attachments, then sends the text with their ids. A message the phone
    /// cannot send for lack of a connection waits, and `flushOutbox` sends it later.
    @discardableResult
    private func deliver(_ id: UUID, restoreOnUploadFailure: Bool = false) async -> Delivery {
        guard let first = outbox.first(where: { $0.id == id }) else { return .failed }
        func mark(_ state: OutgoingMessage.State) {
            if let index = outbox.firstIndex(where: { $0.id == id }) { outbox[index].state = state }
            persistOutbox()
        }
        // A message typed while an earlier one waits or is on its way from the outbox goes behind it, so the Mac sees them in order.
        if let index = outbox.firstIndex(where: { $0.id == id }), outbox[..<index].contains(where: { $0.queuedAt != nil && ($0.isWaiting || $0.state == .sending) }) {
            enqueue(id)
            kickFlush()
            return .offline
        }
        let client = self.client, timeout = sendTimeout
        let text = first.text, reply = first.reply
        var uploadIDs = first.uploadIDs
        var photos: [String: Data] = [:]
        if uploadIDs.isEmpty {
            for file in first.files {
                do {
                    let upload = try await client.upload(file.data, fileName: file.fileName, contentType: file.contentType)
                    uploadIDs.append(upload.id)
                    if file.isImage, let stored = upload.storedName { photos[stored] = file.data }
                } catch ClientError.unauthorized {
                    onUnauthorized()
                    if restoreOnUploadFailure { return .uploadFailed("") }
                    mark(.failed("Sign in again to send."))
                    return .failed
                } catch is CancellationError {
                    mark(.failed("The send was cancelled."))
                    return .failed
                } catch where Self.isUnreachable(error) {
                    enqueue(id)
                    return outbox.contains { $0.id == id && $0.isWaiting } ? .offline : .failed
                } catch {
                    if restoreOnUploadFailure { return .uploadFailed(PlainError.message(for: error)) }
                    mark(.failed("The upload failed. \(PlainError.message(for: error))"))
                    return .failed
                }
            }
            if let index = outbox.firstIndex(where: { $0.id == id }) { outbox[index].uploadIDs = uploadIDs }
        }
        // The id is the message's own, so a Retry sends the same id and the Mac creates the message once.
        let clientID = id.uuidString.lowercased()
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
        } catch where Self.isUnreachable(error) {
            // The Mac is out of reach (no network, asleep, relay down). Keep the message and send it on the next connect. The
            // attachments upload again then, since the Mac may not have kept these.
            if let index = outbox.firstIndex(where: { $0.id == id }) { outbox[index].uploadIDs = [] }
            enqueue(id)
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
    static func isUnreachable(_ error: Error) -> Bool {
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
            message.isVoice = record.isVoice ?? false
            message.local = message.isVoice
            message.audio = record.audioName.flatMap { store.readFile(name: $0) }
            message.files = (record.files ?? []).compactMap { ref in
                store.readFile(name: ref.name).map { StagedFile(fileName: ref.fileName, contentType: ref.contentType, data: $0, isImage: ref.isImage) }
            }
            // A recording or photo whose file is gone cannot be sent. The text, if any, still can.
            if message.isVoice, message.text.isEmpty, message.audio == nil { continue }
            if !message.isVoice, message.text.isEmpty, message.files.isEmpty { continue }
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
            var record = OutboxRecord(id: message.id, text: message.text, date: message.date, queuedAt: queuedAt, replyItemID: message.reply?.itemID, replySelection: message.reply?.selectionText, failure: failure)
            if message.isVoice { record.isVoice = true }
            // The recording is only needed until the Mac has turned it into text.
            if message.isVoice, message.text.isEmpty, let audio = message.audio {
                let name = message.id.uuidString.lowercased() + ".pcm"
                if savedFiles.insert(name).inserted { outboxStore.writeFile(audio, name: name) }
                record.audioName = name
            }
            if !message.files.isEmpty {
                record.files = message.files.enumerated().map { offset, file in
                    let name = message.id.uuidString.lowercased() + "-\(offset)"
                    if savedFiles.insert(name).inserted { outboxStore.writeFile(file.data, name: name) }
                    return OutboxFileRef(name: name, fileName: file.fileName, contentType: file.contentType, isImage: file.isImage)
                }
            }
            return record
        }
        outboxStore.save(records)
        let kept = Set(records.flatMap { [$0.audioName].compactMap { $0 } + ($0.files ?? []).map(\.name) })
        savedFiles.formIntersection(kept)
        outboxStore.prune(keeping: kept)
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
        // The socket's connect refresh repeats the read that launch just made. A read from the last two seconds covers it.
        let repeatsRead = signal == .connected && (lastRead.map { ContinuousClock.now - $0 < .seconds(2) } ?? false)
        if !repeatsRead { await super.handle(signal) }
        switch signal {
        // After a resume the replayed events are already applied, because the Mac sends them before `resumed`. The waiting messages go out now.
        case .connected, .resync, .resumed: kickFlush()
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
            let result = message.isTranscribing && message.audio != nil ? await sendSavedVoice(message.id) : await deliver(message.id)
            switch result {
            case .delivered, .refused: continue
            case .offline, .failed, .uploadFailed: return
            }
        }
    }

    // MARK: Voice

    /// Sends the audio of a failed voice message again. Set by the app to `VoiceModel.resend`.
    @ObservationIgnored var resendVoice: (String) async -> Void = { _ in }

    /// Turns a saved recording into text on the Mac, without putting anything in the chat. Set by the app to
    /// `VoiceModel.transcribeSaved`. The phone sends the text itself afterwards, with the message id as the client id, so the Mac
    /// makes the message once however often the transcription ran.
    @ObservationIgnored var transcribeSaved: (String, Data) async -> SavedTranscript = { _, _ in .unreachable }

    /// True while an earlier message waits or is on its way from the outbox. A voice message recorded now goes behind it.
    var hasEarlierMessages: Bool { outbox.contains { $0.queuedAt != nil && ($0.isWaiting || $0.state == .sending) } }

    /// Sends a saved recording: the Mac transcribes it, then the phone sends the text with the attachments of the message.
    @discardableResult
    private func sendSavedVoice(_ id: UUID) async -> Delivery {
        guard let audio = outbox.first(where: { $0.id == id })?.audio else { return .failed }
        let result = await transcribeSaved(id.uuidString.lowercased(), audio)
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return .failed }
        switch result {
        case .text(let text):
            outbox[index].text = text
            outbox[index].audio = nil
            outbox[index].known = userItemIDs
            persistOutbox()
            return await deliver(id)
        case .empty:
            discardSilent(id)
            return .delivered
        case .unreachable:
            enqueue(id)
            return outbox.contains { $0.id == id && $0.isWaiting } ? .offline : .failed
        case .failed(let reason):
            outbox[index].state = .failed(reason)
            persistOutbox()
            return .failed
        }
    }

    /// The Mac heard no speech. Nothing is sent, and the photos go back to the composer.
    private func discardSilent(_ id: UUID) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        let files = outbox[index].files
        outbox.remove(at: index)
        attachments = files.map { PendingAttachment(fileName: $0.fileName, contentType: $0.contentType, data: $0.data, isImage: $0.isImage) } + attachments
        persistOutbox()
    }

    /// Applies what happened to a voice message sent at once. The stream id is the message id, so the pending item is the one Stop made.
    func voiceEvent(_ event: VoiceModel.SendEvent) {
        func index(_ id: String) -> Int? { UUID(uuidString: id).flatMap { uuid in outbox.firstIndex { $0.id == uuid } } }
        switch event {
        case .started(let id, let carry):
            guard let uuid = UUID(uuidString: id), index(id) == nil else { return }
            var message = OutgoingMessage(id: uuid, text: "", date: Date(), state: .sending, known: userItemIDs)
            message.isVoice = true
            if carry {
                // The attachments in the composer go with the voice message as one message.
                message.local = true
                message.files = attachments.map { StagedFile(fileName: $0.fileName, contentType: $0.contentType, data: $0.data, isImage: $0.isImage) }
                attachments = []
                uploadFailure = nil
            }
            outbox.append(message)
        case .text(let id, let text):
            // The text of a recording the phone sends itself. A recording with no speech sends nothing.
            guard let at = index(id), let uuid = UUID(uuidString: id) else { return }
            if text.isEmpty { return discardSilent(uuid) }
            outbox[at].text = text
            outbox[at].known = userItemIDs
            Task { [weak self] in await self?.deliver(uuid) }
        case .offline(let id, let audio):
            // The phone could not reach the Mac while it recorded. The recording waits like a typed message.
            guard let at = index(id), let uuid = UUID(uuidString: id) else { return }
            outbox[at].audio = audio
            outbox[at].local = true
            enqueue(uuid)
            kickFlush()
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
            network.report(error)
            // A refusal from the Mac is an answer to what the person asked for. A network failure is the strip's to show.
            if case ClientError.api(_, _, let message) = error { errorMessage = message }
        }
        return false
    }
}
