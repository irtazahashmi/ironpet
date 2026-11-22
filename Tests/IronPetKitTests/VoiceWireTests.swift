import XCTest
@testable import IronPetKit

final class VoiceWireTests: XCTestCase {
    func testAudioFramesCarryABigEndianSeq() {
        let frame = VoiceWire.audioFrame(seq: 0x01020304, pcm: Data([9, 8]))
        XCTAssertEqual([UInt8](frame), [0x01, 1, 2, 3, 4, 9, 8])
        let parsed = VoiceWire.parseAudioFrame(frame)
        XCTAssertEqual(parsed?.seq, 0x01020304)
        XCTAssertEqual(parsed?.pcm, Data([9, 8]))
        XCTAssertNil(VoiceWire.parseAudioFrame(Data([0x02, 0, 0, 0, 0])), "a reply frame is not an audio frame")
        XCTAssertNil(VoiceWire.parseAudioFrame(Data([0x01, 0, 0])))
    }

    func testReplyFramesCarryABigEndianIndex() {
        let frame = VoiceWire.ttsFrame(index: 258, wav: Data("RIFF".utf8))
        XCTAssertEqual([UInt8](frame.prefix(5)), [0x02, 0, 0, 1, 2])
        XCTAssertEqual(VoiceWire.parseTTSFrame(frame)?.index, 258)
        XCTAssertEqual(VoiceWire.parseTTSFrame(frame)?.wav, Data("RIFF".utf8))
    }

    func testMessagesRoundTrip() {
        let client: [VoiceClientMessage] = [.start(id: "a", mode: .send), .end(id: "a"), .cancel(id: "a"), .ttsStop, .ttsEnable(true), .ttsSpeak(item: "8a1f")]
        for message in client { XCTAssertEqual(VoiceClientMessage.parse(message.json), message) }
        let server: [VoiceServerMessage] = [.transcript(id: "a", text: "hi \"there\""), .error(id: nil, message: "no"), .error(id: "a", message: "no"),
                                            .ttsChunk(reply: "r", index: 2, last: true), .ttsEnd(reply: "r")]
        for message in server { XCTAssertEqual(VoiceServerMessage.parse(message.json), message) }
        XCTAssertNil(VoiceClientMessage.parse("not json"))
        XCTAssertNil(VoiceClientMessage.parse(#"{"type":"tts.speak"}"#), "a read request names its message")
        XCTAssertNil(VoiceClientMessage.parse(#"{"type":"tts.speak","item":""}"#))
        XCTAssertNil(VoiceServerMessage.parse(#"{"type":"unknown"}"#))
    }

    func testTheStartMessageDeclaresTheFormat() throws {
        let json = VoiceClientMessage.start(id: "a", mode: .draft).json
        let format = try XCTUnwrap(VoiceClientMessage.declaredFormat(json))
        XCTAssertEqual(format.format, "pcm_s16le")
        XCTAssertEqual(format.rate, 16_000)
        XCTAssertEqual(format.channels, 1)
    }

    func testTheFramerNumbersFramesAndKeepsTheRestForTheNextChunk() {
        var framer = VoiceFramer()
        XCTAssertTrue(framer.append(Data(count: 1_000)).isEmpty)
        let frames = framer.append(Data(count: 6_000))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.map { VoiceWire.parseAudioFrame($0)?.seq }, [0, 1])
        XCTAssertTrue(frames.allSatisfy { VoiceWire.parseAudioFrame($0)?.pcm.count == VoiceWire.frameBytes })
        let last = framer.flush()
        XCTAssertEqual(last.flatMap(VoiceWire.parseAudioFrame)?.seq, 2)
        XCTAssertEqual(last.flatMap(VoiceWire.parseAudioFrame)?.pcm.count, 600)
        XCTAssertNil(framer.flush())
    }
}
