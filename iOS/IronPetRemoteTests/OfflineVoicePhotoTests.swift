import XCTest
import IronPetKit
@testable import IronPetRemote

/// A voice socket that is down or up as a test says. When it is up, it answers the end of a stream with a transcript, or with an error.
private final class StubChannel: VoiceChannel, @unchecked Sendable {
    enum Reply { case transcript(String), error(String), silence }
    private let lock = NSLock()
    private var _down = false
    private var _reply: Reply = .transcript("hello there")
    private var _starts: [(id: String, mode: VoiceMode)] = []
    private var _frames = 0
    private let stream: AsyncThrowingStream<VoiceInbound, Error>
    private let continuation: AsyncThrowingStream<VoiceInbound, Error>.Continuation

    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }

    var down: Bool { get { lock.withLock { _down } } set { lock.withLock { _down = newValue } } }
    var reply: Reply { get { lock.withLock { _reply } } set { lock.withLock { _reply = newValue } } }
    var starts: [(id: String, mode: VoiceMode)] { lock.withLock { _starts } }
    var frames: Int { lock.withLock { _frames } }

    func send(text: String) async throws {
        if down { throw URLError(.notConnectedToInternet) }
        switch VoiceClientMessage.parse(text) {
        case .start(let id, let mode)?: lock.withLock { _starts.append((id, mode)) }
        case .end(let id)?:
            switch reply {
            case .transcript(let words): continuation.yield(.text(VoiceServerMessage.transcript(id: id, text: words).json))
            case .silence: continuation.yield(.text(VoiceServerMessage.transcript(id: id, text: "").json))
            case .error(let message): continuation.yield(.text(VoiceServerMessage.error(id: id, message: message).json))
            }
        default: break
        }
    }

    func send(binary: Data) async throws {
        if down { throw URLError(.notConnectedToInternet) }
        lock.withLock { _frames += 1 }
    }

    func incoming() -> AsyncThrowingStream<VoiceInbound, Error> { stream }
    func close() { continuation.finish() }
}

@MainActor
private final class SilentEngine: ClipEngine {
    var onFailure: (@MainActor (String) -> Void)?
    func play(_ wav: Data, onFinish: @escaping @MainActor () -> Void) throws {}
    func stop() {}
}

private final class ToneMic: MicSource {
    private var finish: () -> Void = {}
    var onFailure: (@Sendable (String) -> Void)?

    func start() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        finish = { continuation.finish() }
        continuation.yield(Data(repeating: 7, count: 32_000))
        return stream
    }

    func stop() { finish() }
}

/// Voice and photo messages sent without a connection wait on the phone, survive a relaunch and go out once, in order, after the
/// reconnect. A voice message sent with a staged photo is one message with the photo.
@MainActor
final class OfflineVoicePhotoTests: XCTestCase {
    private var server: MockIronPetServer!
    private let deadEndpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!)

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func chatModel(online: Bool, socket: FakeChatSocket, store: MemoryOutboxStore) -> ChatModel {
        let client = online ? IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token) : IronPetClient(endpoint: deadEndpoint, token: "t")
        let events = SharedEventSource(EventConnection(client: client))
        let model = ChatModel(client: client, events: events, onUnauthorized: {})
        model.socket = socket
        model.useOutbox(store)
        return model
    }

    private func voiceModel(channel: StubChannel, chat: ChatModel) -> VoiceModel {
        let voice = VoiceModel(player: ReplyPlayer(engine: SilentEngine()), defaults: UserDefaults(suiteName: "offline-voice-\(UUID().uuidString)")!, openChannel: { channel }, makeMic: { ToneMic() })
        voice.sendAtOnce = true
        voice.onSend = { [chat] in chat.voiceEvent($0) }
        voice.hasComposerContent = { [chat] in chat.hasComposerContent }
        voice.hasEarlierMessages = { [chat] in chat.hasEarlierMessages }
        chat.resendVoice = { [voice] in await voice.resend($0) }
        chat.transcribeSaved = { [voice] in await voice.transcribeSaved($0, $1) }
        return voice
    }

    private func record(_ voice: VoiceModel) async {
        await voice.micTapped()
        await voice.micTapped()
    }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func photo(_ chat: ChatModel, _ name: String = "photo-1.jpg") {
        chat.attach(data: Data(repeating: 9, count: 2_000), fileName: name, contentType: "image/jpeg")
    }

    private var userItems: [RemoteChatItem] { server.chat.items.filter { $0.kind == "user" && $0.origin == "ios" } }
    private var photoItems: [RemoteChatItem] { server.chat.items.filter { $0.kind == "screenshot" } }

    // S1
    func testAVoiceMessageRecordedOfflineWaitsAndIsTranscribedAndSentOnceAfterTheReconnect() async {
        let socket = FakeChatSocket(open: false), store = MemoryOutboxStore(), channel = StubChannel()
        let chat = chatModel(online: true, socket: socket, store: store)
        let voice = voiceModel(channel: channel, chat: chat)
        channel.down = true
        await record(voice)
        let waiting = try? XCTUnwrap(chat.outbox.first)
        XCTAssertEqual(chat.outbox.count, 1)
        XCTAssertTrue(waiting?.isWaiting == true)
        XCTAssertTrue(waiting?.isVoice == true)
        XCTAssertEqual(waiting?.audio?.count, 32_000, "the whole recording is kept")
        XCTAssertEqual(chat.displayItems.last?.text, "Transcribing…")
        XCTAssertEqual(store.records.first?.audioName != nil, true, "the recording is saved to a file")
        XCTAssertFalse(chat.awaitingReply)
        XCTAssertTrue(socket.sent.isEmpty)

        channel.down = false
        socket.setOpen(true)
        await chat.flushOutbox()
        XCTAssertEqual(socket.sent.map(\.text), ["hello there"])
        XCTAssertEqual(socket.sent.first?.clientID, waiting?.id.uuidString.lowercased(), "the message id is the client id")
        XCTAssertEqual(channel.starts.last?.mode, .draft, "the Mac only turns the audio into text")
        XCTAssertTrue(chat.outbox.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.files.isEmpty, "the recording file is deleted once the text is sent")
        await chat.flushOutbox()
        XCTAssertEqual(socket.sent.count, 1, "a second flush sends nothing")
    }

    // S2
    func testAPhotoSentOfflineWaitsAndGoesOutOnceAfterTheReconnect() async {
        let store = MemoryOutboxStore()
        let offline = chatModel(online: false, socket: FakeChatSocket(open: false), store: store)
        photo(offline)
        await offline.send()
        XCTAssertEqual(offline.outbox.count, 1)
        XCTAssertTrue(offline.outbox[0].isWaiting)
        XCTAssertEqual(offline.displayItems.last?.text, "Photo")
        XCTAssertTrue(offline.attachments.isEmpty, "the photo left the composer")
        XCTAssertEqual(store.files.count, 1)

        let online = chatModel(online: true, socket: FakeChatSocket(open: true), store: store)
        await online.flushOutbox()
        XCTAssertEqual(photoItems.count, 1)
        XCTAssertTrue(online.outbox.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.files.isEmpty)
        await online.flushOutbox()
        XCTAssertEqual(photoItems.count, 1, "a second flush sends nothing")
    }

    // S3 and S4
    func testTextThenVoiceThenPhotoGoOutOnceInOrderAfterARelaunch() async {
        let store = MemoryOutboxStore(), channel = StubChannel()
        let offline = chatModel(online: false, socket: FakeChatSocket(open: false), store: store)
        let voice = voiceModel(channel: channel, chat: offline)
        offline.draft = "one"
        await offline.send()
        channel.down = true
        await record(voice)
        photo(offline)
        await offline.send()
        XCTAssertEqual(offline.outbox.map(\.isVoice), [false, true, false])
        XCTAssertTrue(offline.outbox.allSatisfy(\.isWaiting))

        // The app is killed offline and starts again online. The queue comes back from the saved files.
        let socket = FakeChatSocket(open: true)
        var order: [String] = []
        socket.onSend = { @Sendable in }
        let relaunched = chatModel(online: true, socket: socket, store: store)
        XCTAssertEqual(relaunched.outbox.map(\.isVoice), [false, true, false])
        XCTAssertEqual(relaunched.outbox[1].audio?.count, 32_000)
        XCTAssertEqual(relaunched.outbox[2].files.count, 1)
        relaunched.transcribeSaved = { _, _ in
            order.append("voice")
            return .text("two")
        }
        await relaunched.flushOutbox()
        XCTAssertEqual(order, ["voice"])
        XCTAssertEqual(socket.sent.map(\.text), ["one", "two"], "text, then the voice message's words")
        XCTAssertEqual(photoItems.count, 1, "the photo goes last, once")
        XCTAssertTrue(relaunched.outbox.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        await relaunched.flushOutbox()
        XCTAssertEqual(socket.sent.count, 2)
        XCTAssertEqual(photoItems.count, 1)
    }

    // S6
    func testAMacThatRefusesTheSavedAudioKeepsItWithRetry() async {
        let store = MemoryOutboxStore(), channel = StubChannel()
        let socket = FakeChatSocket(open: true)
        let chat = chatModel(online: true, socket: socket, store: store)
        let voice = voiceModel(channel: channel, chat: chat)
        channel.down = true
        await record(voice)
        channel.down = false
        channel.reply = .error("Voice needs 16 kHz mono 16-bit PCM.")
        await chat.flushOutbox()
        XCTAssertTrue(chat.outbox.first?.isFailed == true, "shows Retry, not lost")
        XCTAssertNotNil(chat.outbox.first?.audio)
        XCTAssertEqual(store.records.first?.audioName != nil, true)
        XCTAssertTrue(socket.sent.isEmpty)

        channel.reply = .transcript("second try")
        await chat.retry(chat.outbox[0].id)
        XCTAssertEqual(socket.sent.map(\.text), ["second try"])
        XCTAssertTrue(chat.outbox.isEmpty)
    }

    func testARecordingWithNoSpeechSendsNothingAndGivesThePhotoBack() async {
        let store = MemoryOutboxStore(), channel = StubChannel()
        let socket = FakeChatSocket(open: true)
        let chat = chatModel(online: false, socket: socket, store: store)
        let voice = voiceModel(channel: channel, chat: chat)
        photo(chat)
        channel.down = true
        await record(voice)
        channel.down = false
        channel.reply = .silence
        await chat.flushOutbox()
        XCTAssertTrue(chat.outbox.isEmpty)
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(chat.attachments.count, 1, "the photo is back in the composer")
    }

    // S7
    func testAVoiceMessageSentWithAStagedPhotoIsOneMessageWithThePhotoOnline() async {
        let store = MemoryOutboxStore(), channel = StubChannel()
        let chat = chatModel(online: true, socket: FakeChatSocket(open: true), store: store)
        let voice = voiceModel(channel: channel, chat: chat)
        photo(chat)
        await record(voice)
        XCTAssertTrue(chat.attachments.isEmpty, "the photo left the composer with the voice message")
        XCTAssertEqual(channel.starts.last?.mode, .draft, "the Mac only turns the audio into text, so it adds no message of its own")
        await poll { self.photoItems.count == 1 && !self.userItems.isEmpty }
        await poll { chat.outbox.isEmpty }
        XCTAssertEqual(userItems.map(\.text), ["hello there"])
        XCTAssertEqual(photoItems.count, 1)
        XCTAssertTrue(chat.outbox.isEmpty)
    }

    func testAVoiceMessageSentWithAStagedPhotoWaitsOfflineAndGoesOutOnce() async {
        let store = MemoryOutboxStore(), channel = StubChannel()
        let offline = chatModel(online: false, socket: FakeChatSocket(open: false), store: store)
        let voice = voiceModel(channel: channel, chat: offline)
        photo(offline)
        channel.down = true
        await record(voice)
        XCTAssertEqual(offline.outbox.count, 1, "one message, not two")
        XCTAssertTrue(offline.outbox[0].isWaiting)
        XCTAssertEqual(offline.outbox[0].files.count, 1)
        XCTAssertNotNil(offline.outbox[0].audio)
        XCTAssertTrue(offline.attachments.isEmpty)

        let relaunchChannel = StubChannel()
        let online = chatModel(online: true, socket: FakeChatSocket(open: true), store: store)
        _ = voiceModel(channel: relaunchChannel, chat: online)
        XCTAssertEqual(online.outbox.count, 1)
        await online.flushOutbox()
        XCTAssertEqual(userItems.map(\.text), ["hello there"])
        XCTAssertEqual(photoItems.count, 1)
        XCTAssertTrue(online.outbox.isEmpty)
        await online.flushOutbox()
        XCTAssertEqual(userItems.count, 1)
        XCTAssertEqual(photoItems.count, 1)
    }

    func testAVoiceMessageWithoutAPhotoStaysOnTheLiveMacPath() async {
        let channel = StubChannel()
        let chat = chatModel(online: true, socket: FakeChatSocket(open: true), store: MemoryOutboxStore())
        let voice = voiceModel(channel: channel, chat: chat)
        await record(voice)
        XCTAssertEqual(channel.starts.last?.mode, .send, "online voice is unchanged")
        XCTAssertFalse(chat.outbox.first?.local ?? true)
    }

    // Voice sends carry the whole composer: the reply quote, the typed text and the attachments.
    private func quoted(_ chat: ChatModel, selection: String? = nil) {
        chat.reply(to: RemoteChatItem(id: "item-7", kind: "assistant", date: Date(), origin: nil, text: "an answer"), selection: selection)
    }

    // S1
    func testAVoiceMessageSentAtOnceCarriesTheReplyQuoteAndClearsIt() async {
        let channel = StubChannel(), socket = FakeChatSocket(open: true)
        let chat = chatModel(online: true, socket: socket, store: MemoryOutboxStore())
        let voice = voiceModel(channel: channel, chat: chat)
        quoted(chat, selection: "answer")
        await record(voice)
        XCTAssertNil(chat.replyTo, "the quote left the composer")
        XCTAssertNil(chat.replySelection)
        XCTAssertEqual(channel.starts.last?.mode, .draft, "the phone sends the message itself, so the quote can go with it")
        await poll { socket.sent.count == 1 }
        XCTAssertEqual(socket.replies.first??.itemID, "item-7")
        XCTAssertEqual(socket.replies.first??.selectionText, "answer")
    }

    // S2
    func testAVoiceMessageSentAtOnceHasTheTypedTextThenTheTranscript() async {
        let channel = StubChannel(), socket = FakeChatSocket(open: true)
        let chat = chatModel(online: true, socket: socket, store: MemoryOutboxStore())
        let voice = voiceModel(channel: channel, chat: chat)
        chat.draft = "  context first  "
        await record(voice)
        XCTAssertEqual(chat.draft, "", "the draft cleared")
        await poll { socket.sent.count == 1 }
        XCTAssertEqual(socket.sent.map(\.text), ["context first\n\nhello there"])
    }

    // S3, online and offline
    func testStagedFilesGoWithAVoiceMessageOnlineAndOfflineAndSurviveARelaunch() async throws {
        let store = MemoryOutboxStore(), channel = StubChannel(), socket = FakeChatSocket(open: true)
        let chat = chatModel(online: true, socket: socket, store: store)
        let voice = voiceModel(channel: channel, chat: chat)
        photo(chat)
        await record(voice)
        await poll { self.photoItems.count == 1 && chat.outbox.isEmpty }
        XCTAssertEqual(photoItems.count, 1, "online: the photo goes with the message")

        // Offline: the typed text, the quote and the photo wait with the recording, and a relaunch keeps them.
        let offline = chatModel(online: false, socket: FakeChatSocket(open: false), store: store)
        let offlineChannel = StubChannel()
        let offlineVoice = voiceModel(channel: offlineChannel, chat: offline)
        offlineChannel.down = true
        offline.draft = "typed"
        quoted(offline)
        photo(offline, "photo-2.jpg")
        await record(offlineVoice)
        XCTAssertEqual(offline.outbox.count, 1)
        XCTAssertEqual(offline.outbox[0].files.count, 1)
        XCTAssertEqual(offline.outbox[0].typedText, "typed")
        XCTAssertEqual(offline.outbox[0].reply?.itemID, "item-7")
        XCTAssertTrue(offline.attachments.isEmpty)
        XCTAssertTrue(offline.draft.isEmpty)
        XCTAssertNil(offline.replyTo)

        offlineChannel.down = false
        let relaunchedSocket = FakeChatSocket(open: true)
        let relaunched = chatModel(online: true, socket: relaunchedSocket, store: store)
        XCTAssertEqual(relaunched.outbox.first?.typedText, "typed")
        XCTAssertEqual(relaunched.outbox.first?.reply?.itemID, "item-7")
        relaunched.transcribeSaved = { _, _ in .text("spoken") }
        await relaunched.flushOutbox()
        let sends = server.requests.filter { $0.path == "/v1/chat/current/messages" }
        let last = try XCTUnwrap(sends.last, "the queued message reached the Mac over HTTPS, because it has a photo")
        XCTAssertEqual(last.json["text"] as? String, "typed\n\nspoken")
        XCTAssertEqual((last.json["upload_ids"] as? [String])?.count, 1, "the photo went with it")
        XCTAssertEqual((last.json["reply"] as? [String: Any])?["item_id"] as? String, "item-7")
        XCTAssertTrue(relaunched.outbox.isEmpty)
    }

    // An outbox saved by an earlier build has no typedText and still loads.
    func testAnOutboxSavedBeforeTypedTextExistedStillDecodes() throws {
        let json = #"{"id":"6F2B0C5E-6B1A-4E3C-9D0A-0A1B2C3D4E5F","text":"hi","date":0,"queuedAt":0}"#
        let record = try JSONDecoder().decode(OutboxRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.typedText)
        XCTAssertEqual(record.text, "hi")
    }

    // S4
    func testARecordingWithNoSpeechGivesTheQuoteTheDraftAndThePhotoBack() async {
        let channel = StubChannel(), socket = FakeChatSocket(open: true)
        let chat = chatModel(online: true, socket: socket, store: MemoryOutboxStore())
        let voice = voiceModel(channel: channel, chat: chat)
        channel.reply = .silence
        chat.draft = "typed"
        quoted(chat)
        photo(chat)
        await record(voice)
        await poll { chat.outbox.isEmpty }
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(chat.draft, "typed")
        XCTAssertEqual(chat.attachments.count, 1)
        XCTAssertEqual(chat.replyTo?.id, "item-7")
    }

    // S4, a failed send
    func testAFailedVoiceSendKeepsTheQuoteTheTextAndThePhotoOnTheMessageForRetry() async {
        let store = MemoryOutboxStore(), channel = StubChannel(), socket = FakeChatSocket(open: true)
        let chat = chatModel(online: true, socket: socket, store: store)
        let voice = voiceModel(channel: channel, chat: chat)
        channel.down = true
        chat.draft = "typed"
        quoted(chat)
        photo(chat)
        await record(voice)
        channel.down = false
        channel.reply = .error("Voice needs 16 kHz mono 16-bit PCM.")
        await chat.flushOutbox()
        let failed = chat.outbox.first
        XCTAssertTrue(failed?.isFailed == true)
        XCTAssertEqual(failed?.typedText, "typed")
        XCTAssertEqual(failed?.reply?.itemID, "item-7")
        XCTAssertEqual(failed?.files.count, 1)
        XCTAssertTrue(socket.sent.isEmpty)
    }
}
