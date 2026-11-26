import XCTest
import IronPetKit
@testable import IronPetRemote

private final class Channel: VoiceChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var binaries = 0
    private let stream: AsyncThrowingStream<VoiceInbound, Error>
    private let continuation: AsyncThrowingStream<VoiceInbound, Error>.Continuation
    var failEnd = false

    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }

    var sentTexts: [String] { lock.withLock { texts } }
    var binaryCount: Int { lock.withLock { binaries } }

    func send(text: String) async throws {
        if failEnd, case .end? = VoiceClientMessage.parse(text) { throw URLError(.notConnectedToInternet) }
        lock.withLock { texts.append(text) }
    }

    func send(binary: Data) async throws { lock.withLock { binaries += 1 } }
    func incoming() -> AsyncThrowingStream<VoiceInbound, Error> { stream }
    func close() { continuation.finish() }
}

@MainActor
private final class SilentEngine: ClipEngine {
    var onFailure: (@MainActor (String) -> Void)?
    func play(_ wav: Data, onFinish: @escaping @MainActor () -> Void) throws {}
    func stop() {}
}

/// A mic that gives one second of a tone as soon as it starts, then waits for `stop()`.
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

/// A voice message sent at once shows as a pending item when Stop is tapped, and the Mac's copy replaces it once.
@MainActor
final class VoiceSendTests: XCTestCase {
    var server: MockIronPetServer!

    override func setUpWithError() throws {
        server = MockIronPetServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func poll(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func rig() async -> (chat: ChatModel, voice: VoiceModel, channel: Channel) {
        let client = IronPetClient(endpoint: ServerEndpoint(baseURL: server.baseURL), token: server.token)
        let events = SharedEventSource(EventConnection(client: client, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100))))
        let chat = ChatModel(client: client, events: events, onUnauthorized: {})
        chat.start()
        await poll { chat.loaded && chat.snapshot != nil }
        let channel = Channel()
        let voice = VoiceModel(player: ReplyPlayer(engine: SilentEngine()), defaults: UserDefaults(suiteName: "voice-send-\(UUID().uuidString)")!, openChannel: { channel }, makeMic: { ToneMic() })
        voice.sendAtOnce = true
        voice.onSend = { [chat] in chat.voiceEvent($0) }
        chat.resendVoice = { [voice] in await voice.resend($0) }
        return (chat, voice, channel)
    }

    private func streamID(_ channel: Channel) -> String? {
        for text in channel.sentTexts { if case .start(let id, _)? = VoiceClientMessage.parse(text) { return id } }
        return nil
    }

    // S1
    func testStopShowsAPendingItemWithTheTypingRowAtOnce() async throws {
        let (chat, voice, channel) = await rig()
        await voice.micTapped()
        let start = ContinuousClock.now
        await voice.micTapped()
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(200))
        XCTAssertEqual(chat.displayItems.last?.text, "Transcribing…")
        XCTAssertTrue(chat.awaitingReply)
        XCTAssertNotNil(streamID(channel))
        chat.stop()
    }

    // S2
    func testTheMacsItemReplacesThePendingOneWhicheverArrivesFirst() async throws {
        for itemFirst in [false, true] {
            let (chat, voice, channel) = await rig()
            await voice.micTapped()
            await voice.micTapped()
            let id = try XCTUnwrap(streamID(channel))
            let arrive = {
                self.server.chat.running = false
                self.server.pushUserItem(text: "voice words \(itemFirst)", origin: "ios")
            }
            let transcript = { voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "voice words \(itemFirst)").json)) }
            if itemFirst { arrive(); await poll { chat.items.contains { $0.text == "voice words true" } }; transcript() } else { transcript(); arrive() }
            await poll { chat.items.contains { $0.text == "voice words \(itemFirst)" } }
            XCTAssertEqual(chat.displayItems.filter { $0.text == "voice words \(itemFirst)" }.count, 1)
            XCTAssertTrue(chat.outbox.isEmpty)
            XCTAssertFalse(chat.displayItems.contains { $0.text == "Transcribing…" })
            chat.stop()
        }
    }

    // S3
    func testAFailedUploadShowsTheErrorAndRetrySendsTheSameAudioOnce() async throws {
        let (chat, voice, channel) = await rig()
        channel.failEnd = true
        await voice.micTapped()
        await voice.micTapped()
        let failed = try XCTUnwrap(chat.outbox.first)
        XCTAssertTrue(failed.isFailed)
        XCTAssertFalse(chat.awaitingReply)
        let framesBefore = channel.binaryCount
        channel.failEnd = false
        async let first: Void = chat.retry(failed.id)
        async let second: Void = chat.retry(failed.id)
        _ = await (first, second)
        let ends = channel.sentTexts.filter { if case .end? = VoiceClientMessage.parse($0) { return true } else { return false } }
        XCTAssertEqual(ends.count, 1, "the failed end never reached the channel, and the double tap sent one")
        XCTAssertEqual(channel.binaryCount - framesBefore, framesBefore, "the same frames went out again")
        XCTAssertEqual(chat.outbox.first?.state, .sending)
        chat.stop()
    }

    /// After the event socket opens, the phone does one full read. When that read ends while the single-message read for the pushed
    /// item is in flight, the full read shows the item and the single read's answer is dropped, so `phone.item` is never marked.
    /// The test pins that order with a slow message read instead of hoping the connect-time read lands there.
    func testAFullReadThatEndsDuringTheMessageReadStillConfirmsTheVoiceItem() async throws {
        var hops: [String] = []
        PhoneHopLog.tap = { hops.append($0) }
        defer { PhoneHopLog.tap = nil }
        let (chat, voice, channel) = await rig()
        await poll { self.server.openSocketCount > 0 }
        XCTAssertGreaterThan(server.openSocketCount, 0, "the event socket opened, so the push reaches the phone")
        await voice.micTapped()
        await voice.micTapped()
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "marked").json))
        server.messageReadDelay = 0.4
        server.pushUserItem(text: "marked", origin: "ios")
        await poll { self.server.maxMessageReadsInFlight > 0 }
        XCTAssertGreaterThan(server.maxMessageReadsInFlight, 0, "the single read is in flight before the full read runs")
        // The phone reads the chat with If-None-Match. When the connect-time read already held the pushed item, the next read answers
        // 304 and takes nothing, so no full read would end during the single read. A changed body makes the next read a 200.
        server.chat.running.toggle()
        await chat.reload()
        await poll { chat.outbox.isEmpty }
        let diag = "hops=\(hops) items=\(chat.items.count) reads=\(server.messageReads) sockets=\(server.openSocketCount) err=\(String(describing: chat.errorMessage)) outbox=\(chat.outbox.map(\.state)) loaded=\(chat.loaded)"
        XCTAssertTrue(chat.outbox.isEmpty, diag)
        XCTAssertEqual(chat.items.filter { $0.text == "marked" }.count, 1)
        XCTAssertTrue(hops.contains("phone.confirmed"))
        // The single read is still in flight here. Let it answer so the assertion below sees whether it marked the item.
        await poll { self.server.messageReadsInFlight == 0 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(hops.contains("phone.item"), "the dropped single read does not mark the item")
        chat.stop()
    }

    func testThePushedVoiceItemIsMarkedOnThePhone() async throws {
        var hops: [String] = []
        PhoneHopLog.tap = { hops.append($0) }
        defer { PhoneHopLog.tap = nil }
        let (chat, voice, channel) = await rig()
        await poll { self.server.openSocketCount > 0 }
        await voice.micTapped()
        await voice.micTapped()
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "marked").json))
        server.pushUserItem(text: "marked", origin: "ios")
        await poll { chat.outbox.isEmpty }
        // Which hop confirms it depends on whether the connect-time full read or the single read gets there first, so the test
        // checks the result both paths share: the item is in the transcript once and the outbox entry is gone.
        XCTAssertTrue(chat.outbox.isEmpty)
        XCTAssertEqual(chat.items.filter { $0.text == "marked" }.count, 1)
        XCTAssertTrue(hops.contains("phone.confirmed"))
        chat.stop()
    }

    func testASilentRecordingLeavesNoPendingItem() async throws {
        let (chat, voice, channel) = await rig()
        await voice.micTapped()
        await voice.micTapped()
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "").json))
        XCTAssertTrue(chat.outbox.isEmpty)
        chat.stop()
    }

    // S4
    func testThePhoneMarksEachVoiceHopWithoutContent() async throws {
        // The chat's own reads and events log `phone.item`, `phone.event` and `phone.confirmed` at times the test does not control, and
        // one of them landed between the voice hops. This test is about the voice hops, so it records only those.
        var hops: [String] = []
        PhoneHopLog.tap = { if $0.hasPrefix("phone.voice.") { hops.append($0) } }
        defer { PhoneHopLog.tap = nil }
        let (chat, voice, channel) = await rig()
        await voice.micTapped()
        await voice.micTapped()
        let id = try XCTUnwrap(streamID(channel))
        voice.handle(.text(VoiceServerMessage.transcript(id: id, text: "private words").json))
        XCTAssertEqual(hops, ["phone.voice.stop", "phone.voice.upload.start", "phone.voice.upload.done", "phone.voice.ack"])
        chat.stop()
    }
}
