import IronPetKit
import XCTest
@testable import IronPet
@testable import IronPetCore

/// `/v1/voice` over a real listener: the upgrade rules and one stream in each direction.
@MainActor
final class RemoteVoiceSocketTests: XCTestCase {
    private var h: RemoteServerHarness!
    private var token = ""
    private var deviceID = ""
    private var chat: ChatSession!

    override func setUp() async throws {
        TestMemory.isolate()
        chat = ChatSession(restore: false, speech: SpeechPlayer())
        h = RemoteServerHarness(chat: chat)
        h.api.settings.update { $0.voice.enabled = true }
        try await h.start()
        let paired = try await h.pairDevice()
        token = paired.token
        deviceID = paired.deviceID
    }

    override func tearDown() async throws { await h.stop() }

    private func socket(token: String?) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(h.port)/v1/voice")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = h.session.webSocketTask(with: request)
        task.resume()
        return task
    }

    func testAPhoneStreamsAudioAndGetsTheTranscript() async throws {
        var received: Data?
        h.api.voice.transcribeAudio = { audio, _, _ in received = audio; return "from the socket" }
        let task = socket(token: token)
        try await task.send(.string(VoiceClientMessage.start(id: "a", mode: .draft).json))
        for seq in 0..<3 as Range<UInt32> {
            try await task.send(.data(VoiceWire.audioFrame(seq: seq, pcm: Data(repeating: 3, count: VoiceWire.frameBytes))))
        }
        try await task.send(.string(VoiceClientMessage.end(id: "a").json))
        guard case .string(let text) = try await task.receive() else { return XCTFail("expected text") }
        XCTAssertEqual(VoiceServerMessage.parse(text), .transcript(id: "a", text: "from the socket"))
        XCTAssertEqual(WAV.samples(of: try XCTUnwrap(received)).count, 3 * VoiceWire.frameSamples)
        task.cancel(with: .goingAway, reason: nil)
    }

    func testTheMacSendsReplyAudioAsTextThenBinary() async throws {
        h.api.voice.synthesize = { _ in Data("RIFFwav".utf8) }
        let task = socket(token: token)
        try await task.send(.string(VoiceClientMessage.ttsEnable(true).json))
        try await Task.sleep(for: .milliseconds(200))
        chat.onTurn?(ChatOrigin(client: ChatOrigin.iosClient, ref: deviceID), .finished("One reply."))
        var texts: [String] = []
        var frames: [Data] = []
        while texts.count < 2 || frames.isEmpty {
            switch try await task.receive() {
            case .string(let text): texts.append(text)
            case .data(let data): frames.append(data)
            @unknown default: break
            }
        }
        guard case .ttsChunk(_, 0, true)? = VoiceServerMessage.parse(texts[0]) else { return XCTFail(texts.joined()) }
        XCTAssertEqual(VoiceWire.parseTTSFrame(frames[0])?.wav, Data("RIFFwav".utf8))
        guard case .ttsEnd? = VoiceServerMessage.parse(texts[1]) else { return XCTFail(texts.joined()) }
        task.cancel(with: .goingAway, reason: nil)
    }

    func testTheUpgradeNeedsADeviceToken() async throws {
        let none = socket(token: nil)
        do { _ = try await none.receive(); XCTFail("expected the upgrade to fail") } catch {}
        let wrong = socket(token: "ipt_nope")
        do { _ = try await wrong.receive(); XCTFail("expected the upgrade to fail") } catch {}
    }
}
